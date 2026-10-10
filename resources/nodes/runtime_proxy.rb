# frozen_string_literal: true

require 'json'
require 'pathname'
require 'tempfile'
require 'fileutils'
require 'strscan'
require 'shellwords'

module Empeira
  # Executed with the installed agent Ruby in the owned guest, never on the host.
  # rubocop:disable-next Metrics/ClassLength -- Standalone guest helper contains both native package-manager adapters.
  class RuntimeProxyGuest
    APT_PATH = '/etc/apt/apt.conf.d/90-empeira-proxy'
    DNF_PATH = '/etc/dnf/dnf.conf'
    PROFILE_PATH = '/etc/profile.d/90-empeira-proxy.sh'
    BEGIN_MARKER = "# BEGIN EMPEIRA RUNTIME PROXY\n"
    END_MARKER = "# END EMPEIRA RUNTIME PROXY\n"

    def initialize(request, root: Pathname('/'))
      @desired = request.fetch('desired')
      @accepted = request.fetch('accepted')
      @root = Pathname(root)
    end

    def reconcile
      changed = reconcile_apt if path('/etc/apt').directory?
      changed = reconcile_dnf || changed if path('/etc/dnf').directory?
      reconcile_profile || !!changed
    end

    private

    def profile_content(definition)
      variables = %w[HTTP_PROXY HTTPS_PROXY http_proxy https_proxy].to_h { |key| [key, definition&.fetch('url') || ''] }
      variables.merge!(%w[NO_PROXY no_proxy].to_h { |key| [key, definition&.fetch('no_proxy') || ''] })
      variables.merge!('ALL_PROXY' => '', 'all_proxy' => '')
      exports = variables.map do |key, value|
        "export #{key}=#{Shellwords.escape(value)}\n"
      end.join
      "# Managed by Empeira: normal runtime proxy environment.\n#{exports}"
    end

    # rubocop:disable-next Naming/PredicateMethod -- Clear stale container image environment when disabled.
    def reconcile_profile
      target = path(PROFILE_PATH)
      current = read(target)
      content = profile_content(@desired)
      if current && ![@desired, *@accepted, nil].map { |entry| profile_content(entry) }.include?(current)
        raise 'Foreign or modified /etc/profile.d/90-empeira-proxy.sh; refusing to replace it'
      end
      return false if content == current

      write(target, content)
      true
    end

    def path(value)
      @root.join(value.delete_prefix('/'))
    end

    def read(target)
      target.parent.ascend do |parent|
        raise "Unsafe proxy configuration parent: #{parent}" if parent.symlink?
      end
      stat = target.lstat
      unless stat.file? && stat.nlink == 1 && stat.uid == Process.euid
        raise "Unsafe or unowned proxy configuration: #{target}"
      end

      target.binread
    rescue Errno::ENOENT
      nil
    end

    def write(target, content, mode: 0o644)
      FileUtils.mkdir_p(target.parent, mode: 0o755)
      Tempfile.create('.empeira-proxy-', target.parent) do |file|
        file.chmod(mode)
        file.write(content)
        file.flush
        file.fsync
        File.rename(file.path, target)
      end
    end

    def apt_content(definition, foreign = {})
      return unless definition

      url = definition.fetch('url')
      globals = "// Managed by Empeira: normal proxy, no bootstrap credentials.\n" \
                "Acquire::http::Proxy \"#{url}\";\nAcquire::https::Proxy \"#{url}\";\n"
      globals + direct_lines(definition).reject { |line| foreign.key?(line.split.first.downcase) }.join
    end

    def direct_lines(definition)
      definition.fetch('direct').flat_map do |host|
        %w[http https].map { |protocol| "Acquire::#{protocol}::Proxy::#{host} \"DIRECT\";\n" }
      end
    end

    def owned_apt?(current, definition)
      globals = apt_content(definition.merge('direct' => []))
      return false unless current.start_with?(globals)

      lines = current.delete_prefix(globals).lines
      lines.uniq == lines && (lines - direct_lines(definition)).empty?
    end

    # rubocop:disable-next Naming/PredicateMethod -- Reconciliation mutates the APT fragment.
    def reconcile_apt
      target = path(APT_PATH)
      current = read(target)
      verify_apt_file(current)

      foreign = @desired ? foreign_apt_settings(target) : {}
      verify_apt_globals(foreign) if @desired
      content = apt_content(@desired, foreign)
      return false if content == current

      content ? write(target, content) : target.unlink
      true
    end

    def verify_apt_file(current)
      return unless current
      return if @accepted.any? { |entry| owned_apt?(current, entry) }

      raise 'Foreign or modified /etc/apt/apt.conf.d/90-empeira-proxy; refusing to replace or remove it'
    end

    def foreign_apt_settings(target)
      files = path('/etc/apt/apt.conf.d').glob('*') + [path('/etc/apt/apt.conf')]
      files.each_with_object({}) do |file, settings|
        next if file == target || !file.exist? || file.directory?

        settings.merge!(apt_settings(read(file)).transform_keys(&:downcase))
      end
    end

    def verify_apt_globals(settings)
      settings.slice('acquire::http::proxy', 'acquire::https::proxy').each do |key, value|
        next if [@desired.fetch('url'), "#{@desired.fetch('url')}/"].include?(value)

        raise "Foreign APT #{key} conflicts with the normal Empeira proxy"
      end
    end

    # Parse native flat and nested scopes; host-specific proxy/DIRECT keys remain untouched.
    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Parse flat and nested native APT scopes without evaluating configuration.
    def apt_settings(content)
      scanner = StringScanner.new(content)
      scopes = []
      statement = []
      values = {}
      until scanner.eos?
        next if scanner.scan(%r{\s+|//[^\n]*|/\*.*?\*/|#(?!(?:include|clear)\b)[^\n]*}m)

        token = scanner.scan(/"(?:\\.|[^"\\])*"|[^\s{};]+|[{};]/)
        raise 'Cannot safely parse foreign APT configuration' unless token
        raise 'Foreign APT #include/#clear requires explicit proxy configuration review' if token.start_with?('#')

        case token
        when '{' then scopes << statement.join('::')
                      statement = []
        when '}' then scopes.pop
                      statement = []
        when ';'
          values[[*scopes, statement.first].compact.join('::')] =
            statement.last&.delete_prefix('"')&.delete_suffix('"')
          statement = []
        else statement << token
        end
      end
      values
    end

    def dnf_content(definition)
      return '' unless definition

      "#{BEGIN_MARKER}proxy=#{definition.fetch('url')}\n#{END_MARKER}"
    end

    # rubocop:disable-next Naming/PredicateMethod -- Reconciliation mutates the DNF main block.
    def reconcile_dnf
      target = path(DNF_PATH)
      current = read(target)
      raise 'Missing /etc/dnf/dnf.conf; refusing to initialize foreign configuration' unless current

      block = current[/#{Regexp.escape(BEGIN_MARKER)}.*?#{Regexp.escape(END_MARKER)}/m]
      verify_dnf_block(current, block)
      foreign = block ? current.sub(block, '') : current
      desired = dnf_content(@desired)
      content = integrate_dnf(foreign, desired)
      return false if current == content

      write(target, content, mode: target.stat.mode & 0o777)
      true
    end

    def verify_dnf_block(current, block)
      return unless current.include?(BEGIN_MARKER) || current.include?(END_MARKER)
      return if owned_dnf_block?(current, block)

      raise 'Modified Empeira DNF proxy block; refusing to replace or remove it'
    end

    def owned_dnf_block?(current, block)
      block && @accepted.map { |entry| dnf_content(entry) }.include?(block) &&
        current.scan(BEGIN_MARKER).size == 1 && current.scan(END_MARKER).size == 1 &&
        current.match?(/^\s*\[main\][^\n]*\n#{Regexp.escape(block)}/i)
    end

    def integrate_dnf(content, desired)
      sections = content.split(/(?=^\s*\[)/)
      main = sections.grep(/\A\s*\[main\]\s*\n/i)
      raise 'DNF requires one unambiguous [main] section for normal proxy integration' unless main.size == 1

      verify_dnf_proxy(main.first) if @desired
      # Insert directly after the section header without changing any existing lines.
      replacement = main.first.sub(/(\A\s*\[main\][^\n]*\n)/i) { "#{Regexp.last_match(1)}#{desired}" }
      sections.map { |section| section.equal?(main.first) ? replacement : section }.join
    end

    def verify_dnf_proxy(section)
      section.each_line do |line|
        match = /^\s*proxy\s*=\s*(.*?)\s*$/i.match(line)
        next unless match
        next if match[1] == @desired.fetch('url')

        raise 'Foreign DNF [main] proxy conflicts with the normal Empeira proxy; repository overrides are preserved'
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.generate('changed' => Empeira::RuntimeProxyGuest.new(JSON.parse(ARGV.fetch(0))).reconcile)
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
