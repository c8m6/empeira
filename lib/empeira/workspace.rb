# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'

module Empeira
  class Workspace
    attr_reader :id, :path

    def self.recover(path, user_home: Dir.home)
      root = recovery_root(path)
      user = Pathname(user_home).realpath.to_s
      identity = allocate
      identity.instance_variable_set(:@id, Digest::SHA256.hexdigest(JSON.generate([user, root.to_s]))[0, 24].freeze)
      identity.instance_variable_set(:@path, root.freeze)
      identity.freeze
    rescue SystemCallError
      raise ConfigurationError, 'Recovery project path and user home must be accessible'
    end

    def self.recovery_root(path)
      unless path.is_a?(String) && !path.include?("\0") && Pathname(path).absolute?
        raise ConfigurationError, 'Recovery project path must be an absolute former Git root path'
      end

      root = Pathname(path).cleanpath
      root.exist? ? root.realpath : root
    end

    def initialize(path: Dir.pwd, user_home: Dir.home)
      @path = ProjectRoot.resolve(path).path
      raise ConfigurationError, 'project path must be a directory' unless @path.directory?

      user = Pathname(user_home).realpath.to_s
      @id = Digest::SHA256.hexdigest(JSON.generate([user, @path.to_s]))[0, 24].freeze
      freeze
    rescue SystemCallError
      raise ConfigurationError, 'project path and user home must exist and be accessible'
    end
  end
end
