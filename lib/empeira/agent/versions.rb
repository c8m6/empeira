# frozen_string_literal: true

module Empeira
  module Agent
    # Exact identity matching only; ordering remains the native package manager's responsibility.
    module Versions
      module_function

      def match?(native, requested, suffix: nil)
        return native == "#{requested}#{suffix}" if suffix
        return true if native == requested
        return false if requested.include?('-') || requested.include?(':')

        native.split(':').last.split('-', 2).first == requested
      end

      def select(candidates, requested, suffix: nil)
        matches = candidates.select { |candidate| match?(candidate.fetch('version'), requested, suffix: suffix) }.uniq
        raise Error, 'Requested agent version is unavailable in the selected source' if matches.empty?
        if matches.size > 1
          raise Error,
                'Requested agent version is ambiguous; specify the full native version or suffix'
        end

        matches.first
      end
    end
  end
end
