# frozen_string_literal: true

# rubocop:disable Style/FormatStringToken -- RPM and DNF use their native query-format tokens.

module Empeira
  module Node
    # DNF metadata is queried against the isolated source directory only.
    # rubocop:disable-next Metrics/ClassLength -- DNF and RPM share one isolated source and its temporary trusted keys.
    class DnfAgentRepository < AgentRepository
      REPO_PATH = '/var/tmp/empeira-agent-repos/agent.repo'
      KEY_PATH = '/var/tmp/empeira-agent-rpm-key.gpg'
      CONFIG_PATH = '/var/tmp/empeira-agent-dnf.conf'
      PACKAGE_PATH = '/var/tmp/empeira-agent-package.rpm'
      QUERY_FORMAT = '%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{reponame}'

      def resolve
        @release_package = nil
        @release_sources = {}
        @repository_ids = []
        install_source
        result = native!([*dnf_command, 'repoquery', "--archlist=#{@target.native_architecture},noarch",
                          '--qf', QUERY_FORMAT, @package], 'DNF package resolution')
        candidates = result.stdout.lines.filter_map { |line| dnf_candidate(line) }
        candidate = Agent::Versions.select(candidates, @version, suffix: @source['suffix'])
        candidate.merge('url' => package_url(candidate))
      ensure
        remove_release_package if @release_package
      end

      def prepare_keys
        key = super
        execute!(['rpmkeys', '--import', key], 'RPM signing key import') if key
        key
      end

      def inspect_package(path)
        @copy.call(path, PACKAGE_PATH, '0600')
        result = execute!(['rpm', '-qp', '--qf', '%{NAME}|%{EPOCHNUM}:%{VERSION}-%{RELEASE}|%{ARCH}', PACKAGE_PATH],
                          'RPM package inspection')
        name, version, architecture = result.stdout.strip.split('|')
        version = version.delete_prefix('0:') if version
        metadata = validate_metadata(name, version, architecture)
        verify_signature unless @source['verify_signatures'] == false
        metadata
      end

      private

      def install_source
        execute!(['mkdir', '-p', File.dirname(REPO_PATH)], 'source preparation')
        if @source['url'].end_with?('.rpm')
          install_release(@source)
          collect_release_sources
          prepare_keys
        else
          @repository_ids = ['empeira-agent']
          prepare_keys
          copy_text(repo_content, REPO_PATH, mode: '0600')
        end
        copy_text("[main]\ngpgcheck=1\nsslverify=1\nlogfilelevel=0\nreposdir=#{File.dirname(REPO_PATH)}\n",
                  CONFIG_PATH, mode: '0600')
      end

      def install_release(artifact)
        path = download_artifact(artifact, 'release.rpm')
        destination = '/var/tmp/empeira-agent-release.rpm'
        @copy.call(path, destination, '0600')
        name = execute!(['rpm', '-qp', '--qf', '%{NAME}', destination], 'release metadata').stdout.strip
        require_absent_release!(name)
        @release_package = name
        execute!(['rpm', '-i', destination], 'release package installation')
      end

      def collect_release_sources
        files = execute!(['rpm', '-ql', @release_package], 'release source discovery').stdout.lines.map(&:strip)
        files = files.select { |file| file.start_with?('/etc/yum.repos.d/') && file.end_with?('.repo') }
        raise Error, 'Agent release package provides no native DNF source' if files.empty?

        files.each_with_index do |file, index|
          content = execute!(['cat', file], 'release repository configuration').stdout
          import_release_keys(content)
          store_release_source(content, index)
        end
      end

      def store_release_source(content, index)
        path = "#{File.dirname(REPO_PATH)}/#{index}.repo"
        scoped = Agent::ReleaseSources.dnf(content, target: @target, source: @source, package: @package)
        @repository_ids.concat(scoped.scan(/^\[([^\]]+)\]/).flatten)
        @release_sources[path] = scoped
        copy_text(scoped, path, mode: '0600')
      end

      def import_release_keys(content)
        content.scan(/^\s*gpgkey\s*=\s*(.+)$/).flatten.flat_map(&:split).each_with_index do |url, index|
          path = release_key(url, index)
          @public_keys << Base64.strict_encode64(File.binread(path))
          guest_path = "#{KEY_PATH}-#{index}"
          @copy.call(path, guest_path, '0600')
          execute!(['rpmkeys', '--import', guest_path], 'RPM signing key import')
        end
      end

      def release_key(url, index)
        path = File.join(@directory, "release-key-#{index}")
        if url.start_with?('file:///')
          key = execute!(['cat', URI(url).path], 'release signing key').stdout
          File.write(path, key, perm: 0o600)
        else
          @download.fetch(url, path)
        end
        path
      end

      def repo_content
        credentials = @authentication.credentials
        lines = ['[empeira-agent]', 'name=Empeira temporary agent source', "baseurl=#{@source.fetch('url')}",
                 'enabled=1', "gpgcheck=#{@source['verify_signatures'] == false ? 0 : 1}",
                 'sslverify=1', 'skip_if_unavailable=0', "includepkgs=#{@package}"]
        lines.push("username=#{credentials.first}", "password=#{credentials.last}") if credentials
        "#{lines.join("\n")}\n"
      end

      def install_auth
        if @release_package
          @release_sources.each do |path, content|
            copy_text(authenticated_release_content(content), path, mode: '0600')
          end
          return
        end

        copy_text(repo_content, REPO_PATH, mode: '0600')
      end

      def authenticated_release_content(content)
        credentials = @authentication.credentials
        return content unless credentials

        content.gsub(/^(\s*baseurl\s*=\s*)(\S+)$/) do
          line = Regexp.last_match(0)
          url = @target.expand(Regexp.last_match(2))
          if @authentication.credentials(url)
            "#{line}\nusername=#{credentials.first}\npassword=#{credentials.last}"
          else
            line
          end
        end
      end

      def dnf_command
        ['dnf', '--quiet', "--config=#{CONFIG_PATH}", "--releasever=#{@target.release}"]
      end

      def package_url(candidate)
        spec = "#{@package}-#{candidate.fetch('version')}.#{candidate.fetch('architecture')}"
        urls = native!([*dnf_command, 'repoquery', "--repoid=#{candidate.fetch('repository')}", '--location', spec],
                       'DNF artifact location').stdout.lines
               .map(&:strip).uniq
        raise Error, 'Selected agent source did not provide one HTTPS package location' unless urls.size == 1

        Configuration::AgentSchema.https_url!(urls.first, 'agent resolved package URL')
        urls.first
      end

      def dnf_candidate(line)
        name, epoch, version, release, architecture, repository = line.strip.split('|')
        return unless name == @package && [@target.native_architecture, 'noarch'].include?(architecture) &&
                      @repository_ids.include?(repository)

        native = "#{epoch}:#{version}-#{release}".delete_prefix('0:')
        { 'version' => native, 'architecture' => architecture, 'repository' => repository }
      end

      def validate_metadata(name, version, architecture)
        unless name == @package && [@target.native_architecture, 'noarch'].include?(architecture) &&
               Agent::Versions.match?(version.to_s, @version, suffix: @source['suffix'])
          raise Error, 'Agent package name, native version or architecture differs from the requested target'
        end

        { 'version' => version, 'architecture' => architecture }
      end

      def verify_signature
        result = execute!(['rpmkeys', '--checksig', '--verbose', PACKAGE_PATH], 'RPM package signature verification')
        return if result.stdout.match?(/Signature[^\n]*:\s*OK/i) && !result.stdout.match?(/NOKEY|NOT OK/i)

        raise Error, 'Agent RPM package has no verifiable trusted signature'
      end

      def release_inventory_arguments
        ['rpm', '-qa', '--qf', "%{NAME}\n"]
      end

      def release_removal_arguments
        ['rpm', '-e', '--', @release_package]
      end
    end
  end
end

# rubocop:enable Style/FormatStringToken
