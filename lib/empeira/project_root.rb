# frozen_string_literal: true

require 'pathname'
require 'shellwords'

module Empeira
  class ProjectRoot
    attr_reader :path

    def self.resolve(value, runner: nil)
      value.is_a?(self) ? value : new(value, runner: runner || Execution::Runner.new)
    end

    def initialize(path, runner: Execution::Runner.new)
      directory = Pathname(path).realpath
      raise ConfigurationError, 'project path must be an existing directory' unless directory.directory?

      @path = git_root(directory, runner).freeze
      require_marker!
      freeze
    rescue ExecutionError
      raise ConfigurationError, 'An Empeira Git project is required; ensure Git is installed and accessible.',
            cause: nil
    rescue SystemCallError
      raise ConfigurationError, 'project path must be an existing directory accessible to the current user', cause: nil
    end

    private

    def git_root(directory, runner)
      result = runner.run('git', arguments: %w[rev-parse --show-toplevel], directory: directory, timeout: 10)
      unless result.success? && !result.stdout.strip.empty?
        raise ConfigurationError, 'An Empeira Git project is required. Enter a Git repository with .empeira.yaml.'
      end

      Pathname(result.stdout.chomp).realpath
    end

    def require_marker!
      marker = @path.join('.empeira.yaml')
      return if marker.file?

      raise ConfigurationError, "Empeira project #{@path} is missing marker #{marker}. " \
                                "Opt in with: touch #{Shellwords.escape(marker.to_s)}"
    end
  end
end
