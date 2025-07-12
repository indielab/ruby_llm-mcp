# frozen_string_literal: true

require "json"
require "uri"
require "httpx"
require "timeout"
require "securerandom"

module RubyLLM
  module MCP
    module Transports
      class SSE
        include Timeout

        attr_reader :headers, :id, :coordinator

        def initialize(url:, coordinator:, request_timeout:, version: :http2, headers: {})
          @event_url = url
          @messages_url = nil
          @coordinator = coordinator
          @request_timeout = request_timeout
          @version = version

          uri = URI.parse(url)
          @root_url = "#{uri.scheme}://#{uri.host}"
          @root_url += ":#{uri.port}" if uri.port != uri.default_port

          @client_id = SecureRandom.uuid
          @headers = headers.merge({
                                     "Accept" => "text/event-stream",
                                     "Content-Type" => "application/json",
                                     "Cache-Control" => "no-cache",
                                     "Connection" => "keep-alive",
                                     "X-CLIENT-ID" => @client_id
                                   })

          @id_counter = 0
          @id_mutex = Mutex.new
          @pending_requests = {}
          @pending_mutex = Mutex.new
          @connection_mutex = Mutex.new
          @running = false
          @sse_thread = nil

          RubyLLM::MCP.logger.info "Initializing SSE transport to #{@event_url} with client ID #{@client_id}"
        end

        def request(body, add_id: true, wait_for_response: true)
          if add_id
            @id_mutex.synchronize { @id_counter += 1 }
            request_id = @id_counter
            body["id"] = request_id
          end

          response_queue = Queue.new
          if wait_for_response
            @pending_mutex.synchronize do
              @pending_requests[request_id.to_s] = response_queue
            end
          end

          begin
            send_request(body, request_id)
          rescue Errors::TransportError, Errors::TimeoutError => e
            @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
            RubyLLM::MCP.logger.error "Request error (ID: #{request_id}): #{e.message}"
            raise e
          end

          return unless wait_for_response

          begin
            with_timeout(@request_timeout / 1000, request_id: request_id) do
              response_queue.pop
            end
          rescue Errors::TimeoutError => e
            @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
            RubyLLM::MCP.logger.error "SSE request timeout (ID: #{request_id}) after #{@request_timeout / 1000} seconds"
            raise e
          end
        end

        def alive?
          @running
        end

        def start
          return if @running

          @running = true
          start_sse_listener
        end

        def close
          RubyLLM::MCP.logger.info "Closing SSE transport connection"
          @running = false
          @sse_thread&.join(1) # Give the thread a second to clean up
          @sse_thread = nil
        end

        def set_protocol_version(version)
          @protocol_version = version
        end

        private

        def send_request(body, request_id)
          http_client = HTTPX.with(timeout: { request_timeout: @request_timeout / 1000 },
                                   headers: @headers)
          response = http_client.post(@messages_url, body: JSON.generate(body))
          handle_httpx_error_response!(response,
                                       context: { location: "message endpoint request", request_id: request_id })

          unless [200, 202].include?(response.status)
            message = "Failed to have a successful request to #{@messages_url}: #{response.status} - #{response.body}"
            RubyLLM::MCP.logger.error(message)
            raise Errors::TransportError.new(
              message: message,
              code: response.status
            )
          end
        end

        def start_sse_listener
          @connection_mutex.synchronize do
            return if sse_thread_running?

            RubyLLM::MCP.logger.info "Starting SSE listener thread"

            response_queue = Queue.new
            @pending_mutex.synchronize do
              @pending_requests["endpoint"] = response_queue
            end

            @sse_thread = Thread.new do
              listen_for_events while @running
            end
            @sse_thread.abort_on_exception = true

            with_timeout(@request_timeout / 1000) do
              endpoint = response_queue.pop
              set_message_endpoint(endpoint)
            end
          end
        end

        def set_message_endpoint(endpoint)
          uri = URI.parse(endpoint)

          @messages_url = if uri.host.nil?
                            "#{@root_url}#{endpoint}"
                          else
                            endpoint
                          end

          RubyLLM::MCP.logger.info "SSE message endpoint set to: #{@messages_url}"
        end

        def sse_thread_running?
          @sse_thread&.alive?
        end

        def listen_for_events
          stream_events_from_server
        rescue StandardError => e
          handle_connection_error("SSE connection error", e)
        end

        def stream_events_from_server
          sse_client = HTTPX.plugin(:stream)
          sse_client = sse_client.with(
            headers: @headers
          )

          if @version == :http1
            sse_client = sse_client.with(
              ssl: { alpn_protocols: ["http/1.1"] }
            )
          end

          response = sse_client.get(@event_url, stream: true)

          event_buffer = []
          response.each_line do |event_line|
            unless @running
              response.body.close
              next
            end

            # Strip the line and check if it's empty (indicates end of event)
            line = event_line.strip

            if line.empty?
              # End of event - process the accumulated buffer
              if event_buffer.any?
                event = parse_event(event_buffer.join("\n"))
                process_event(event)
                event_buffer.clear
              end
            else
              # Accumulate the line for the current event
              event_buffer << line
            end
          end
        end

        def handle_connection_error(message, error)
          return unless @running

          error_message = "#{message}: #{error.message}"
          RubyLLM::MCP.logger.error "#{error_message}. Reconnecting in 1 seconds..."
          sleep 1
        end

        def handle_httpx_error_response!(response, context:)
          return false unless response.is_a?(HTTPX::ErrorResponse)

          error = response.error

          if error.is_a?(HTTPX::ReadTimeoutError)
            raise Errors::TimeoutError.new(
              message: "Request timed out after #{@request_timeout / 1000} seconds"
            )
          end

          error_message = response.error&.message || "Request failed"

          raise Errors::TransportError.new(
            code: nil,
            message: "Request Error #{context}: #{error_message}"
          )
        end

        def process_event(raw_event)
          # Return if we believe that are getting a partial event
          return if raw_event[:data].nil?

          if raw_event[:event] == "endpoint"
            request_id = "endpoint"
            event = raw_event[:data]
            return if event.nil?

            RubyLLM::MCP.logger.debug "Received endpoint event: #{event}"
            @pending_mutex.synchronize do
              response_queue = @pending_requests.delete(request_id)
              response_queue&.push(event)
            end
          else
            event = begin
              JSON.parse(raw_event[:data])
            rescue JSON::ParserError => e
              # We can sometimes get partial endpoint events, so we will ignore them
              unless @endpoint.nil?
                RubyLLM::MCP.logger.info "Failed to parse SSE event data: #{raw_event[:data]} - #{e.message}"
              end

              nil
            end
            return if event.nil?

            request_id = event["id"]&.to_s
            result = RubyLLM::MCP::Result.new(event)

            result = @coordinator.process_result(result)
            return if result.nil?

            @pending_mutex.synchronize do
              # You can receieve duplicate events for the same request id, and we will ignore thoses
              if result.matching_id?(request_id) && @pending_requests.key?(request_id)
                response_queue = @pending_requests.delete(request_id)
                response_queue&.push(result)
              end
            end
          end
        end

        def parse_event(raw)
          event = {}
          raw.each_line do |line|
            case line
            when /^data:\s*(.*)/
              (event[:data] ||= []) << ::Regexp.last_match(1)
            when /^event:\s*(.*)/
              event[:event] = ::Regexp.last_match(1)
            when /^id:\s*(.*)/
              event[:id] = ::Regexp.last_match(1)
            end
          end
          event[:data] = event[:data]&.join("\n")
          event
        end
      end
    end
  end
end
