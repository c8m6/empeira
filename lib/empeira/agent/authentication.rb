# frozen_string_literal: true

require 'io/console'
require 'uri'
require 'base64'

module Empeira
  module Agent
    class AuthenticationRequired < Error; end

    class Authentication
      def self.credentials
        values = %w[EMPEIRA_AGENT_REPO_USERNAME EMPEIRA_AGENT_REPO_PASSWORD].map { |key| ENV.fetch(key, nil) }
        return if values.all?(&:nil?)
        return values if valid?(values)

        raise ConfigurationError, 'Set both nonempty EMPEIRA_AGENT_REPO_USERNAME and ' \
                                  'EMPEIRA_AGENT_REPO_PASSWORD for agent repository authentication'
      end

      def self.valid?(values)
        values.all? { |value| value.is_a?(String) && !value.empty? && !value.match?(/[\x00-\x1f\x7f]/) } &&
          !values.first.include?(':')
      end

      def initialize(url:, progress: Progress.new, input: $stdin, output: $stderr)
        @origin = URI(url)
        @credentials = self.class.credentials
        @progress = progress
        @input = input
        @output = output
      end

      def credentials(url = @origin.to_s)
        uri = URI(url)
        @credentials if [uri.scheme, uri.host, uri.port] == [@origin.scheme, @origin.host, @origin.port]
      end

      def attempt
        yield
      rescue AuthenticationRequired
        raise Error, failure_message if @credentials

        login
        begin
          yield
        rescue AuthenticationRequired
          raise Error, failure_message
        end
      end

      def redact(value)
        secrets = [*@credentials, (Base64.strict_encode64(@credentials.join(':')) if @credentials)].compact
        sorted = secrets.sort_by { |secret| -secret.length }
        sorted.reduce(value.to_s) { |text, secret| text.gsub(secret, '[REDACTED]') }
      end

      private

      def failure_message
        'Agent repository authentication failed. Set both EMPEIRA_AGENT_REPO_USERNAME and ' \
          'EMPEIRA_AGENT_REPO_PASSWORD; explicit credentials were not replaced'
      end

      def login
        unless @input.tty? && @output.tty?
          raise Error, 'Agent repository requires authentication; set EMPEIRA_AGENT_REPO_USERNAME and ' \
                       'EMPEIRA_AGENT_REPO_PASSWORD in noninteractive environments'
        end

        @progress.streaming { read_credentials }
      end

      def read_credentials
        @output.puts("Agent repository requires authentication: #{@origin.host}")
        @output.print('Log in? [y/N] ')
        @output.flush
        raise Error, 'Agent repository login cancelled' unless @input.gets&.strip&.match?(/\Ay(?:es)?\z/i)

        username = read_value('Username: ')
        password = read_value('Password: ', secret: true)
        @output.puts
        values = [username, password]
        raise Error, 'Agent repository login cancelled or credentials are invalid' unless self.class.valid?(values)

        @credentials = values
      end

      def read_value(prompt, secret: false)
        @output.print(prompt)
        @output.flush
        (secret ? @input.noecho(&:gets) : @input.gets)&.chomp
      end
    end
  end
end
