# frozen_string_literal: true

# SPDX-License-Identifier: AGPL-3.0-only
# Guest-only supervisor, invoked by an owned native container exec as numeric UID 0.
require 'json'
require 'timeout'

module EmpeiraDiagnosticExec
  ROOT = '/run/empeira-exec'

  # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- Both root and session directory must remain private numeric-root paths.
  def self.directory(token, create: false)
    raise 'Invalid diagnostic identity' unless token.match?(/\A[0-9a-f]{32}\z/)

    path = File.join(ROOT, token)
    [ROOT, path].each do |entry|
      if create
        begin
          Dir.mkdir(entry, 0o700)
        rescue Errno::EEXIST
          raise 'Existing diagnostic session' if entry == path
        end
      end
      metadata = File.lstat(entry)
      unless metadata.directory? && metadata.uid.zero? && metadata.mode.nobits?(0o077)
        raise 'Unsafe diagnostic directory'
      end
    end
    path
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Scan only the pinned owned process session before TERM/KILL.
  def self.cleanup_groups
    groups = Dir.glob('/proc/[0-9]*/stat').filter_map do |path|
      fields = File.read(path).rpartition(') ').last.split
      Integer(fields[2]) if Integer(fields[3]) == Process.pid && Integer(fields[2]) != Process.getpgrp
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end.uniq
    %w[TERM KILL].each do |signal|
      groups.each do |group|
        Process.kill(signal, -group)
      rescue Errno::ESRCH
        nil
      end
      sleep 0.1 if signal == 'TERM' && !groups.empty?
    end
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- Completion is published only after interruption, timeout and owned-group cleanup.
  def self.run(token, duration, arguments)
    raise 'Diagnostic supervisor requires UID 0' unless Process.uid.zero?

    path = directory(token, create: true)
    begin
      Process.setsid
    rescue Errno::EPERM
      raise unless Process.getsid == Process.pid
    end
    owner = Thread.current
    monitor = Thread.new do
      $stdin.read(1)
      owner.raise Interrupt
    end
    environment = { 'PATH' => '/opt/puppetlabs/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' }
    pid = Process.spawn(environment, [arguments.first, arguments.first], *arguments.drop(1),
                        in: File::NULL, pgroup: true)
    status = Timeout.timeout(duration == 'none' ? nil : Float(duration)) { Process.wait2(pid).last }
    result = { 'status' => status.exitstatus || (128 + status.termsig), 'timed_out' => false }
  rescue Interrupt
    result = { 'status' => 130, 'timed_out' => false }
  rescue Timeout::Error
    result = { 'status' => nil, 'timed_out' => true }
  rescue SystemCallError => e
    warn "Guest command could not start (#{e.class.name})"
    result = { 'status' => e.is_a?(Errno::ENOENT) ? 127 : 126, 'timed_out' => false }
  ensure
    monitor&.kill&.join
    cleanup_groups if path && Process.getsid == Process.pid
    begin
      Process.wait(pid) if pid
    rescue Errno::ECHILD
      nil
    end
    if result && path
      File.open(File.join(path, 'status'), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(result))
      end
    end
  end

  def self.completion(token)
    path = directory(token)
    file = File.join(path, 'status')
    metadata = File.lstat(file)
    raise 'Unsafe diagnostic completion' unless metadata.file? && metadata.uid.zero? && metadata.mode.nobits?(0o077)

    print File.read(file, 1024)
    File.unlink(file)
    Dir.rmdir(path)
  end
end

mode, token, duration, *arguments = ARGV
if mode == 'read'
  EmpeiraDiagnosticExec.completion(token)
else
  EmpeiraDiagnosticExec.run(token, duration, arguments)
end
