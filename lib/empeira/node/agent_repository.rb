# frozen_string_literal: true

require 'uri'
require 'digest'
require 'base64'

module Empeira
  module Node
    # Native source setup and package inspection run only in an owned disposable helper.
    # rubocop:disable-next Metrics/ClassLength -- APT metadata resolution and package inspection share one isolated source.
    class AgentRepository
      include Agent::NativeCommands

      AUTH_PATH = '/etc/apt/auth.conf.d/00-empeira-agent.conf'
      SOURCE_PATH = '/var/tmp/empeira-agent-sources/agent.list'
      KEY_PATH = '/var/tmp/empeira-agent-key.gpg'
      PACKAGE_PATH = '/var/tmp/empeira-agent-package.deb'
      attr_reader :public_keys

      def self.credentials
        Agent::Authentication.credentials
      end

      # rubocop:disable-next Metrics/ParameterLists -- The helper receives explicit transport and target dependencies.
      def initialize(source:, package:, version:, target:, execute:, copy:, download:, authentication:, directory:)
        @source = source
        @package = package
        @version = version
        @target = target
        @execute = execute
        @copy = copy
        @download = download
        @authentication = authentication
        @directory = directory
        @public_keys = []
      end

      def resolve
        @release_package = nil
        install_source
        native!(['apt-get', *apt_options, 'update'], 'APT metadata acquisition')
        result = native!(['apt-cache', *apt_options, 'show', '--', @package], 'APT package resolution')
        candidates = result.stdout.split(/\n\s*\n/).filter_map { |stanza| apt_candidate(stanza) }
        Agent::Versions.select(candidates, @version, suffix: @source['suffix'])
      ensure
        remove_release_package if @release_package
      end

      def inspect_package(path)
        @copy.call(path, PACKAGE_PATH, '0600')
        result = execute!(['dpkg-deb', '--show', '--showformat=${Package}|${Version}|${Architecture}', PACKAGE_PATH],
                          'DEB package inspection')
        name, version, architecture = result.stdout.strip.split('|')
        validate_metadata(name, version, architecture)
      end

      def prepare_keys
        return unless @source['key']

        path = download_artifact(@source.fetch('key'), 'signing-key')
        @public_keys << Base64.strict_encode64(File.binread(path))
        key = File.binread(path).start_with?('-----BEGIN PGP PUBLIC KEY BLOCK-----') ? "#{KEY_PATH}.asc" : KEY_PATH
        @copy.call(path, key, '0644')
        key
      end

      private

      def install_source
        execute!(['mkdir', '-p', File.dirname(SOURCE_PATH), '/var/tmp/empeira-agent-lists/partial'],
                 'source preparation')
        if @source['release'] || !@source.key?('suite')
          install_release(@source['release'] || @source)
          collect_release_sources
        else
          install_repository
        end
      end

      def install_repository
        key = prepare_keys
        options = []
        options << "signed-by=#{key}" if key
        options << 'trusted=yes' if @source['verify_signatures'] == false
        line = "deb [#{options.join(' ')}] #{@source.fetch('url')} #{@source.fetch('suite')} " \
               "#{@source.fetch('component')}\n"
        copy_text(line.sub('[] ', ''), SOURCE_PATH, mode: '0644')
      end

      def install_release(artifact)
        path = download_artifact(artifact, 'release.deb')
        destination = '/var/tmp/empeira-agent-release.deb'
        @copy.call(path, destination, '0600')
        name = execute!(['dpkg-deb', '--field', destination, 'Package'], 'release metadata').stdout.strip
        require_absent_release!(name)
        @release_package = name
        execute!(['dpkg', '-i', destination], 'release package installation')
      end

      def collect_release_sources
        files = execute!(['dpkg-query', '-L', @release_package], 'release source discovery').stdout.lines.map(&:strip)
        files = files.select do |file|
          file.start_with?('/etc/apt/sources.list.d/') && file.match?(/\.(?:list|sources)\z/)
        end
        raise Error, 'Agent release package provides no native APT source' if files.empty?

        files.each_with_index do |file, index|
          copy_release_source(file, index)
        end
      end

      def copy_release_source(file, index)
        content = execute!(['cat', file], 'release source configuration').stdout
        content = Agent::ReleaseSources.apt(content, format: File.extname(file), source: @source)
        copy_text(content, "/var/tmp/empeira-agent-sources/#{index}#{File.extname(file)}", mode: '0644')
      end

      def apt_options
        ['-o', 'Dir::Etc::sourcelist=/dev/null', '-o', 'Dir::Etc::sourceparts=/var/tmp/empeira-agent-sources',
         '-o', 'Dir::State::lists=/var/tmp/empeira-agent-lists', '-o', 'Dir::State::status=/dev/null',
         '-o', 'Acquire::http::AllowRedirect=false', '-o', 'Acquire::https::AllowRedirect=false',
         '-o', 'APT::Update::Error-Mode=any']
      end

      def apt_candidate(stanza)
        fields = apt_fields(stanza)
        return unless apt_identity?(fields) && %w[Filename Version SHA256].all? { |key| fields[key] }

        return unless Agent::Versions.match?(fields.fetch('Version'), @version, suffix: @source['suffix'])

        { 'version' => fields.fetch('Version'), 'architecture' => fields.fetch('Architecture'),
          'url' => package_url(fields.fetch('Version')), 'sha256' => fields.fetch('SHA256') }
      end

      def apt_fields(stanza)
        stanza.lines.filter_map do |line|
          line.split(': ', 2) if line.match?(/\A\w[^:]*: /)
        end.to_h.transform_values(&:strip)
      end

      def apt_identity?(fields)
        fields['Package'] == @package && [@target.native_architecture, 'all'].include?(fields['Architecture'])
      end

      def package_url(version)
        result = native!(['apt-get', *apt_options, '--print-uris', 'download', "#{@package}=#{version}"],
                         'APT artifact location')
        urls = result.stdout.lines.filter_map { |line| line[%r{\A'(https://[^']+)'}, 1] }.uniq
        raise Error, 'Selected agent source did not provide one HTTPS package location' unless urls.size == 1

        urls.first
      end

      def validate_metadata(name, version, architecture)
        unless name == @package && [@target.native_architecture, 'all'].include?(architecture) &&
               Agent::Versions.match?(version.to_s, @version, suffix: @source['suffix'])
          raise Error, 'Agent package name, native version or architecture differs from the requested target'
        end

        { 'version' => version, 'architecture' => architecture }
      end
    end
  end
end
