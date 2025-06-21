# frozen_string_literal: true

RSpec.describe RubyLLM::Chat do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    ClientRunner.build_client_runners(CLIENT_OPTIONS)
    ClientRunner.start_all
  end

  after(:all) do # rubocop:disable RSpec/BeforeAfterAll
    ClientRunner.stop_all
  end

  before do
    RubyLLM.configure do |config|
      config.openai_api_key = ENV.fetch("OPENAI_API_KEY", "test")
      config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY", "test")
      config.gemini_api_key = ENV.fetch("GEMINI_API_KEY", "test")
      config.deepseek_api_key = ENV.fetch("DEEPSEEK_API_KEY", "test")
      config.openrouter_api_key = ENV.fetch("OPENROUTER_API_KEY", "test")

      config.bedrock_api_key = ENV.fetch("AWS_ACCESS_KEY_ID", "test")
      config.bedrock_secret_key = ENV.fetch("AWS_SECRET_ACCESS_KEY", "test")
      config.bedrock_region = ENV.fetch("AWS_REGION", "us-west-2")
      config.bedrock_session_token = ENV.fetch("AWS_SESSION_TOKEN", nil)

      config.request_timeout = 240
      config.max_retries = 10
      config.retry_interval = 1
      config.retry_backoff_factor = 3
      config.retry_interval_randomness = 0.5
    end
  end

  around do |example|
    cassette_name = example.full_description
                           .delete_prefix("RubyLLM::Chat ")
                           .gsub(" ", "_")
                           .gsub("/", "_")

    VCR.use_cassette(cassette_name) do
      example.run
    end
  end

  CLIENT_OPTIONS.each do |options|
    context "with #{options[:name]}" do
      let(:client) { ClientRunner.client_runners[options[:name]].client }

      COMPLEX_FUNCTION_MODELS.each do |config|
        context "with #{config[:provider]}/#{config[:model]}" do
          describe "with_tools" do
            it "adds tools to the chat" do
              chat = RubyLLM.chat(model: config[:model])
              chat.with_tools(*client.tools)

              response = chat.ask("Can you add 1 and 2?")
              expect(response.content).to include("3")
            end

            it "adds a select amount of tools" do
              chat = RubyLLM.chat(model: config[:model])
              weather_tools = client.tools.select { |tool| tool.name.include?("weather") }

              chat.with_tools(*weather_tools)

              response = chat.ask("Can you tell me the weather for Ottawa and San Francisco?")
              expect(response.content).to include("Ottawa")
              expect(response.content).to include("San Francisco")
              expect(response.content).to include("great")
            end
          end

          describe "with_tool" do
            it "adds a tool to the chat" do
              chat = RubyLLM.chat(model: config[:model])
              tool = client.tool("list_messages")
              chat.with_tool(tool)

              response = chat.ask("Can you pull messages for ruby channel and let me know what they say?")
              expect(response.content).to include("Ruby is a great language")
            end

            it "can you a complex tool" do
              chat = RubyLLM.chat(model: config[:model])
              tool = client.tool("fetch_site")
              chat.with_tool(tool)

              response = chat.ask("Can you fetch the website http://www.google.com and see if the site say what they do?")
              expect(response.content).to include("Google")
            end
          end

          describe "with_resources" do
            it "adds multiple resources to the chat" do
              chat = RubyLLM.chat(model: config[:model])
              text_resources = client.resources.select { |resource| resource.mime_type&.include?("text") }
              chat.with_resources(*text_resources)

              response = chat.ask("What information do you have from the provided resources?")
              expect(response.content).to include("test")
            end

            it "adds binary resources to the chat" do
              chat = RubyLLM.chat(model: config[:model])
              binary_resources = client.resources.select do |resource|
                resource.mime_type&.include?("image") || resource.mime_type&.include?("audio")
              end
              chat.with_resources(*binary_resources)

              response = chat.ask("What resources do you have access to?")
              expect(response.content).to match(/dog|jackhammer|image|audio/i)
            end
          end

          describe "with_resource" do
            it "adds a single text resource to the chat" do
              chat = RubyLLM.chat(model: config[:model])
              resource = client.resource("test.txt")
              chat.with_resource(resource)

              response = chat.ask("What does the test file contain?")
              expect(response.content).to include("test")
            end

            it "adds a markdown resource to the chat" do
              chat = RubyLLM.chat(model: config[:model])
              resource = client.resource("my.md")
              chat.with_resource(resource)

              response = chat.ask("What does the markdown file say?")
              expect(response.content).to match(/markdown|header|content/i)
            end

            it "adds an image resource to the chat" do
              chat = RubyLLM.chat(model: config[:model])
              resource = client.resource("dog.jpeg")
              chat.with_resource(resource)

              response = chat.ask("What image do you have?")
              expect(response.content).to match(/dog|image|picture/i)
            end
          end

          describe "with_resource_template" do
            it "adds resource templates to the chat and uses them" do
              chat = RubyLLM.chat(model: config[:model])
              template = client.resource_templates.first
              chat.with_resource_template(template, arguments: { name: "Alice" })

              response = chat.ask("Can you greet Alice using the greeting template?")
              expect(response.content).to include("Alice")
            end

            it "handles template arguments correctly" do
              chat = RubyLLM.chat(model: config[:model])
              template = client.resource_template("greeting")
              chat.with_resource_template(template, arguments: { name: "Bob" })

              response = chat.ask("Use the greeting template to say hello to Bob")
              expect(response.content).to include("Bob")
            end
          end

          describe "ask_prompt" do
            it "handles prompts when available" do
              chat = RubyLLM.chat(model: config[:model])
              prompts = client.prompts

              prompt = prompts.first
              response = chat.ask_prompt(prompt)
              expect(response.content).to include("Hello!")
            end

            it "get one prompts by name" do
              chat = RubyLLM.chat(model: config[:model])
              prompt = client.prompt("poem_of_the_day")
              response = chat.ask_prompt(prompt)
              expect(response.content).to include("poem")
            end

            it "handles prompts with arguments" do
              chat = RubyLLM.chat(model: config[:model])
              prompt = client.prompt("specific_language_greeting")
              response = chat.ask_prompt(prompt, arguments: { name: "John", language: "Spanish" })
              expect(response.content).to include("John")
            end
          end
        end
      end
    end
  end
end
