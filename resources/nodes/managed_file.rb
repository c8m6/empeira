# frozen_string_literal: true

require 'json'
require 'pathname'
require 'tempfile'
require 'fileutils'

module Empeira
  # Runs inside the owned guest using its agent Ruby; no separate guest inventory.
  class ManagedFile
    def initialize(request)
      @path = Pathname(request.fetch('path'))
      @content = request['content']
      @accepted = request.fetch('accepted')
      @mode = request.fetch('mode')
    end

    # rubocop:disable-next Naming/PredicateMethod -- Reconciliation mutates the managed file.
    def reconcile
      verify_parents!
      current = verify_file!
      return false if current.nil? && @content.nil?
      return false if current && current == @content && (@path.stat.mode & 0o7777) == @mode

      if @content.nil?
        @path.unlink
      else
        write
      end
      true
    end

    private

    def verify_parents!
      @path.parent.ascend do |parent|
        next unless parent.exist? || parent.symlink?
        next if !parent.symlink? && parent.directory?

        raise 'Managed file parent must be a directory, not a symlink'
      end
    end

    def verify_file!
      stat = @path.lstat
      @content ? current_for_write(stat) : current_for_removal(stat)
    rescue Errno::ENOENT
      nil
    end

    def current_for_write(stat)
      raise 'Command-mock target must be a file or symlink' unless stat.file? || stat.symlink?

      return nil if stat.symlink? || stat.size != @content.bytesize

      @path.binread
    end

    def current_for_removal(stat)
      unless stat.file? && stat.nlink == 1 && stat.uid == Process.euid
        raise 'Refusing to remove an unowned or modified command-mock target'
      end

      content = @path.binread
      raise 'Refusing to remove an unowned or modified command-mock target' unless @accepted.include?(content)

      content
    end

    def write
      FileUtils.mkdir_p(@path.parent, mode: 0o755)
      Tempfile.create('.empeira-', @path.parent) do |file|
        file.chmod(@mode)
        file.write(@content)
        file.flush
        file.fsync
        File.rename(file.path, @path)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    changed = Empeira::ManagedFile.new(JSON.parse(ARGV.fetch(0))).reconcile
    puts JSON.generate('changed' => changed)
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
