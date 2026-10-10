# frozen_string_literal: true

module Empeira
  module Completion
    # Shared CLI vocabulary and context parsing stay in one shell-neutral catalog.
    # rubocop:disable-next Metrics/ClassLength
    class Catalog
      COMMANDS = {
        [] => %w[help version config proxy up status down destroy node images self-update update browser completion],
        ['update'] => ['help', *Updates::Service::TARGETS],
        ['proxy'] => %w[help show],
        ['config'] => %w[help show validate],
        ['node'] => %w[help run start stop destroy list shell ssh puppet logs],
        ['completion'] => %w[help bash],
        ['version'] => ['--verbose']
      }.tap { |commands| Immutable.deep_freeze(commands) }
      GLOBAL_OPTIONS = %w[--container-engine --help].freeze
      NODE_OPTIONS = %w[--provider --os --version --memory --cpus].freeze
      VALUE_OPTIONS = %w[--container-engine --provider --os --version --memory --cpus --user
                         --identity --port].freeze

      def candidates(words, index)
        before = words.take(index)
        @before = before
        prefix = words[index].to_s
        context = command_path(before)
        assignment = assignment_prefix(prefix, before)
        return assignment_candidates(assignment, context) if assignment

        choices = values(pending_option(before), context)
        choices ||= context_choices(context)
        choices.grep(/^#{Regexp.escape(prefix)}/)
      end

      private

      def context_choices(context)
        Array(node_names(context)) + COMMANDS.fetch(context, []) + options(context)
      end

      def assignment_candidates(assignment, context)
        option, value, replacement = assignment
        values(option, context).to_a.grep(/^#{Regexp.escape(value)}/).map { |item| "#{replacement}#{item}" }
      end

      def assignment_prefix(prefix, before)
        if prefix.start_with?('--') && prefix.include?('=')
          option, value = prefix.split('=', 2)
          return [option, value, "#{option}="] if VALUE_OPTIONS.include?(option)
        elsif prefix.start_with?('=') && VALUE_OPTIONS.include?(before.last)
          return [before.last, prefix.delete_prefix('='), '=']
        end
        nil
      end

      def pending_option(before)
        option = before.last == '=' ? before[-2] : before.last
        option&.delete_suffix('=')
      end

      def command_path(words)
        path = []
        pending_value = false
        words.each do |word|
          if pending_value
            pending_value = word == '='
          elsif value_option?(word, path)
            pending_value = true
          elsif command_word?(word, path)
            path << word
          end
        end
        path
      end

      def value_option?(word, path)
        option = word.delete_suffix('=')
        VALUE_OPTIONS.include?(option) && !(option == '--version' && path.empty?)
      end

      def command_word?(word, path)
        !word.start_with?('-') && path.size < 2
      end

      def values(option, context)
        return Configuration::Schema::CONTAINER_ENGINES if option == '--container-engine'
        return Empeira::Node.registry.names if option == '--provider' && context == %w[node run]
        return node_values(option) if %w[--os --version].include?(option) && context == %w[node run]
        return [] if VALUE_OPTIONS.include?(option)

        nil
      end

      def node_names(context)
        return unless context.size == 2 && context.first == 'node' && %w[start stop destroy shell ssh puppet
                                                                         logs].include?(context.last)

        completion_application.nodes.names
      rescue Error
        []
      end

      def completion_application
        Application.new
      end

      def option_value(option)
        @before.each_with_index.filter_map do |word, index|
          if word == option || word == "#{option}="
            value = @before[index + 1]
            value == '=' ? @before[index + 2] : value&.delete_prefix('=')
          elsif word.start_with?("#{option}=")
            word.split('=', 2).last
          end
        end.last
      end

      def node_values(option)
        images = completion_application.context.configuration.dig('images', 'nodes')
        return images.keys if option == '--os'

        images.fetch(selected_os || completion_application.context.configuration.dig('node_defaults', 'os'), {}).keys
      rescue Error
        []
      end

      def selected_os
        option_value('--os')
      end

      def options(context)
        result = GLOBAL_OPTIONS.dup
        result << '--version' if context.empty?
        result.push('--user', '--identity', '--port') if context == %w[node ssh]
        result.concat(NODE_OPTIONS) if context == %w[node run]
        result
      end
    end
  end
end
