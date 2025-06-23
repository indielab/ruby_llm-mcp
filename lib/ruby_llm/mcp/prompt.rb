# frozen_string_literal: true

module RubyLLM
  module MCP
    class Prompt
      class Argument
        attr_reader :name, :description, :required

        def initialize(name:, description:, required:)
          @name = name
          @description = description
          @required = required
        end
      end

      attr_reader :name, :description, :arguments, :coordinator

      def initialize(coordinator, prompt)
        @coordinator = coordinator
        @name = prompt["name"]
        @description = prompt["description"]
        @arguments = parse_arguments(prompt["arguments"])
      end

      def fetch(arguments = {})
        fetch_prompt_messages(arguments)
      end

      def include(chat, arguments: {})
        validate_arguments!(arguments)
        messages = fetch_prompt_messages(arguments)

        messages.each { |message| chat.add_message(message) }
        chat
      end

      def ask(chat, arguments: {}, &)
        include(chat, arguments: arguments)

        chat.complete(&)
      end

      alias say ask

      def complete(argument, value)
        if @coordinator.capabilities.completion?
          response = @coordinator.completion_prompt(name: @name, argument: argument, value: value)
          response = response.dig("result", "completion")

          Completion.new(values: response["values"], total: response["total"], has_more: response["hasMore"])
        else
          raise Errors::CompletionNotAvailable.new(message: "Completion is not available for this MCP server")
        end
      end

      private

      def fetch_prompt_messages(arguments)
        response = @coordinator.execute_prompt(
          name: @name,
          arguments: arguments
        )

        response["result"]["messages"].map do |message|
          content = create_content_for_message(message["content"])

          RubyLLM::Message.new(
            role: message["role"],
            content: content
          )
        end
      end

      def validate_arguments!(incoming_arguments)
        @arguments.each do |arg|
          if arg.required && incoming_arguments.key?(arg.name)
            raise Errors::PromptArgumentError, "Argument #{arg.name} is required"
          end
        end
      end

      def create_content_for_message(content)
        case content["type"]
        when "text"
          MCP::Content.new(text: content["text"])
        when "image", "audio"
          attachment = MCP::Attachment.new(content["content"], content["mime_type"])
          MCP::Content.new(text: nil, attachments: [attachment])
        when "resource"
          resource = Resource.new(coordinator, content["resource"])
          resource.to_content
        end
      end

      def parse_arguments(arguments)
        if arguments.nil?
          []
        else
          arguments.map do |arg|
            Argument.new(name: arg["name"], description: arg["description"], required: arg["required"])
          end
        end
      end
    end
  end
end
