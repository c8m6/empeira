# frozen_string_literal: true

require 'json'
require 'pathname'
require 'rbconfig'
require 'shellwords'
require 'tempfile'
require 'fileutils'

module Empeira
  class InteractiveToolsGuest
    PROFILE = '/etc/profile.d/90-empeira-tools.sh'
    BEGIN_MARKER = "# BEGIN EMPEIRA INTERACTIVE TOOLS\n"
    END_MARKER = "# END EMPEIRA INTERACTIVE TOOLS\n"

    def initialize(request, root: Pathname('/'))
      @root = Pathname(root)
      @candidates = [Pathname(request.fetch('puppet')).dirname.to_s, RbConfig::CONFIG.fetch('bindir')].uniq
    end

    def reconcile
      directory = tool_directory
      changed = profile(directory)
      global_initializers.each { |target| changed = bash(target) || changed }
      { 'changed' => changed, 'directory' => directory }
    end

    private

    def tool_directory
      directory = @candidates.find do |candidate|
        %w[puppet facter].all? { |command| path(candidate).join(command).executable? }
      end
      directory || raise('Cannot locate installed puppet and facter tools together')
    end

    def global_initializers
      initializers = %w[/etc/bash.bashrc /etc/bashrc].map { |value| path(value) }.select(&:exist?)
      raise 'No supported global Bash initializer; inspect the image shell setup' if initializers.empty?

      initializers
    end

    def path(value)
      @root.join(value.delete_prefix('/'))
    end

    def read(target)
      target.parent.ascend do |parent|
        raise 'Unsafe interactive startup directory' if parent.symlink?
      end
      stat = target.lstat
      unless stat.file? && stat.nlink == 1 && stat.uid == Process.euid && stat.mode.nobits?(0o022)
        raise 'Unsafe or unowned interactive startup file'
      end

      target.binread
    rescue Errno::ENOENT
      nil
    end

    def write(target, content, mode: nil)
      FileUtils.mkdir_p(target.parent, mode: 0o755)
      mode ||= target.exist? ? target.stat.mode & 0o777 : 0o644
      Tempfile.create('.empeira-tools-', target.parent) do |file|
        file.chmod(mode)
        file.write(content)
        file.flush
        file.fsync
        File.rename(file.path, target)
      end
    end

    def profile_content(directory)
      <<~SH
        # Managed by Empeira: installed agent tools, interactive shells only.
        case $- in
          *i*)
            empeira_tool_bin=#{Shellwords.escape(path(directory).to_s)}
            case ":${PATH-}:" in
              *":${empeira_tool_bin}:"*) ;;
              *) PATH="${empeira_tool_bin}${PATH:+:$PATH}"; export PATH ;;
            esac
            unset empeira_tool_bin
            ;;
        esac
      SH
    end

    # rubocop:disable-next Naming/PredicateMethod -- Reconciliation writes an owned profile fragment.
    def profile(directory)
      target = path(PROFILE)
      current = read(target)
      if current && @candidates.none? { |candidate| current == profile_content(candidate) }
        raise 'Foreign or modified /etc/profile.d/90-empeira-tools.sh; refusing to overwrite it'
      end

      content = profile_content(directory)
      return false if current == content && (target.stat.mode & 0o777) == 0o644

      write(target, content, mode: 0o644)
      true
    end

    def hook
      <<~SH
        #{BEGIN_MARKER.chomp}
        case $- in
          *i*) . #{Shellwords.escape(path(PROFILE).to_s)} ;;
        esac
        #{END_MARKER.chomp}
      SH
    end

    # rubocop:disable-next Naming/PredicateMethod -- Preserve every foreign line in the global Bash initializer.
    def bash(target)
      current = read(target)
      if current.include?(BEGIN_MARKER) || current.include?(END_MARKER)
        unless current.scan(BEGIN_MARKER).size == 1 && current.scan(END_MARKER).size == 1 && current.include?(hook)
          raise 'Modified Empeira global Bash hook; refusing to overwrite it'
        end

        return false
      end

      write(target, "#{hook}#{current}")
      true
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.generate(Empeira::InteractiveToolsGuest.new(JSON.parse(ARGV.fetch(0))).reconcile)
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
