# frozen_string_literal: true

module Empeira
  module Node
    # Containers use the already installed agent Ruby runtime, never Cloud-Init.
    class ContainerBootstrap
      INSTALL = <<~RUBY
        require 'fileutils'
        path, content, mode = ARGV
        FileUtils.mkdir_p(File.dirname(path), mode: 0755)
        File.write(path, content, mode: 'w', perm: mode.to_i(8))
        File.chmod(mode.to_i(8), path)
      RUBY
      VERIFY = <<~RUBY
        path, content, mode = ARGV
        exit(File.binread(path) == content && (File.stat(path).mode & 0777) == mode.to_i(8) ? 0 : 1)
      RUBY

      def initialize(runtime:)
        @runtime = runtime
      end

      def apply(resource:, bootstrap:)
        bootstrap.files.each do |file|
          run!(resource, INSTALL, file, 'install')
          run!(resource, VERIFY, file, 'verify')
        end
      end

      private

      def run!(resource, code, file, action)
        arguments = [Certificates::RUBY, '-e', code, file.path, file.content, format('%04o', file.mode)]
        return if @runtime.service_exec(resource, arguments).success?

        raise Error, "Cannot #{action} required Empeira node bootstrap file #{file.path}; Puppet was not run"
      end
    end
  end
end
