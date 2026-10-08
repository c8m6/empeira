# frozen_string_literal: true

require 'etc'

# Puppet creates the test login and authorizes a synthetic developer key.
class LoginFixture
  attr_reader :identity, :username

  def initialize(directory:)
    @identity = Pathname(directory).join('developer-key')
    @username = Etc.getpwuid(Process.uid).name
    result = Empeira::Execution::Runner.new.run('ssh-keygen',
                                                arguments: ['-q', '-t', 'ed25519', '-N', '', '-f', identity.to_s])
    raise 'Cannot create synthetic developer key' unless result.success?
  end

  def manifest
    key = Pathname("#{identity}.pub").read.strip
    <<~PUPPET
      group { '#{username}': ensure => present }
      user { '#{username}': ensure => present, gid => '#{username}',
        managehome => true, shell => '/bin/bash', require => Group['#{username}'] }
      file { '/home/#{username}/.ssh': ensure => directory, mode => '0700',
        owner => '#{username}', group => '#{username}', require => User['#{username}'] }
      file { '/home/#{username}/.ssh/authorized_keys': ensure => file, mode => '0600',
        owner => '#{username}', group => '#{username}', content => "#{key}\\n",
        require => File['/home/#{username}/.ssh'] }
    PUPPET
  end
end
