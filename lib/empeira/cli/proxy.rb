# frozen_string_literal: true

module Empeira
  module CLI
    class Proxy < Base
      desc 'show HOSTNAME', 'Explain the normal proxy destination policy for a hostname'
      def show(hostname)
        config = application.context.configuration.fetch('proxy')
        resolver = Network::HostPolicy.new(config)
        say "Effective proxy policy for #{hostname.downcase}"
        say access_message(config)
        display_list('Global', config.fetch('global'))
        display_matches(resolver.matching(hostname))
        display_list('Allowed', resolver.resolve(hostname))
        say 'Managed bootstrap destinations are separate from this normal policy.'
      end
      no_commands do
        def access_message(config)
          return "All workspace nodes may use this policy after 'empeira up' reconciles the proxy." if
            config.fetch('enabled')

          'The normal workspace proxy is disabled.'
        end

        def display_matches(rules)
          display_list('Matched rules', rules.map { |rule| rule.fetch('hosts').join(', ') })
        end

        def display_list(title, entries)
          say "#{title}:"
          entries.each { |entry| say "  #{entry}" }
        end
      end
    end
  end
end
