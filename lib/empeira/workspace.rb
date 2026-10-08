# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'

module Empeira
  class Workspace
    attr_reader :id, :path

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
