# frozen_string_literal: true

require 'pathname'
require 'tmpdir'

module Empeira
  module Platform
    class Locations
      attr_reader :cache, :state, :temporary, :home

      def initialize(facts: Facts.new, home: Dir.home, environment: ENV, temporary_root: Dir.tmpdir)
        @home = Pathname(home)
        @environment = environment
        @cache, @state = roots(facts.os).map { |path| path.join('empeira') }
        @temporary = Pathname(temporary_root)
      end

      def workspace(identity)
        state.join('workspaces', identity.id)
      end

      def user_configuration
        home.join('.empeira.yaml')
      end

      def image(identity)
        cache.join('images', identity.cache_key)
      end

      private

      def roots(os)
        case os
        when :macos then [@home.join('Library/Caches'), @home.join('Library/Application Support')]
        else
          [absolute_environment('XDG_CACHE_HOME', @home.join('.cache')),
           absolute_environment('XDG_STATE_HOME', @home.join('.local/state'))]
        end
      end

      def absolute_environment(key, fallback)
        value = @environment[key]
        value && Pathname(value).absolute? ? Pathname(value) : fallback
      end
    end
  end
end
