# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/addon_source'
require 'pty'

# Explicit acceptance gate: real addon sources are supplied by the caller, never
# downloaded while running the deterministic suite. Only synthetic projects run.
class OfficialAddonSource < AddonSource
  def initialize(directory, checkout)
    @checkout = Pathname(checkout).realpath
    super(directory)
  end

  def prepare_git
    git('init', '--quiet', '--initial-branch=fixture', @directory.to_s)
    @checkout.children.reject { |path| path.basename.to_s == '.git' }.each do |path|
      FileUtils.cp_r(path, @directory)
    end
    commit_changes
    git('-C', @directory.to_s, 'tag', 'v1')
  end
end

names = ENV.fetch('EMPEIRA_OFFICIAL_ADDONS', 'convert,pre-commit,sync').split(',')
raise 'Unknown official addon' unless !names.empty? && (names - %w[convert pre-commit sync]).empty?

names.each do |name|
  RSpec.describe "Official #{name} addon through Core" do
    include AddonFixture

    let(:source) do
      checkout = File.join(ENV.fetch('EMPEIRA_OFFICIAL_ADDON_ROOT'), "empeira-addon-#{name}")
      OfficialAddonSource.new(@directory, checkout).start
    end
    before { configure_addon(name: name) }
    after { source.close }

    it 'validates the real manifest, installs lazily, reuses the cache and updates revisions' do
      entry = addon_application.addons.installation(name)
      expect(entry.local).to be_nil
      expect(official_cli(name, '--help')).to be_success
      original = entry.local
      expect(original[2].executable).to be_file
      expect(official_cli(name, '--help')).to be_success
      expect(entry.local[1].stat.ino).to eq(original[1].stat.ino)
      source.directory.join('acceptance.txt').write('new synthetic revision')
      source.commit_changes
      expect(official_cli(name, '--help')).to be_success
      expect(entry.local.first).to eq(original.first)
      expect(addon_cli('addons', 'update')).to be_success
      expect(entry.local.first).to eq(source.commit)
      expect(original[1]).to exist
      source.directory.join('empeira-addon.yaml').write('schema: 99')
      source.commit_changes
      expect(addon_cli('addons', 'update')).not_to be_success
      expect(official_cli(name, '--help')).to be_success
    end

    it 'keeps real terminal I/O and native help through the CLI handoff' do
      output = +''
      preload = File.expand_path('../support/isolated_cli_locations.rb', __dir__)
      PTY.spawn({ 'EMPEIRA_TEST_HOME' => File.join(@directory, 'user-home') }, RbConfig.ruby,
                '-r', preload, File.expand_path('../../bin/empeira', __dir__), 'addon', name, '--help',
                chdir: addon_project) do |reader, writer, pid|
        writer.close
        begin
          loop { output << reader.readpartial(4096) }
        rescue Errno::EIO, EOFError
          # Linux reports EIO when a PTY closes; macOS may report EOF.
        end
        _, status = Process.wait2(pid)
        expect(status.exitstatus).to eq(0)
      end
      expect(output).to include('Usage:')
    end

    it 'returns the native error for opaque invalid arguments without shell evaluation' do
      result = official_cli(name, '--unsupported-$(touch sentinel)')
      expect(result.exit_status).to eq(1)
      expect(result.stderr).to include('Error:')
      expect(File).not_to exist(File.join(addon_project, 'sentinel'))
    end

    def official_cli(name, *arguments, **options)
      addon_cli('addon', name, *arguments, **options)
    end

    case name
    when 'convert'
      it 'converts files with spaces and generates EPP using the installed addon' do
        input = File.join(addon_project, 'synthetic input.json')
        output = File.join(addon_project, 'synthetic output.yaml')
        File.write(input, JSON.generate('message' => 'synthetic data', 'enabled' => true))
        result = official_cli(name, 'run', '-i', input, '-o', output)
        expect(result.stderr).to be_empty
        expect(result).to be_success
        expect(YAML.safe_load_file(output)).to eq('message' => 'synthetic data', 'enabled' => true)
        expect(official_cli(name, 'template', '-i', input).stdout).to include('<%- |', '$message')
      end
    when 'pre-commit'
      it 'discovers control and Hiera repositories from Core exports without an engine' do
        hiera = File.join(addon_project, 'hiera fixture')
        initialize_project(hiera)
        extra = { 'hiera' => { 'mounts' => [{ 'source' => 'hiera fixture', 'type' => 'module', 'name' => 'common' }] } }
        configure_addon(name: name, extra: extra)
        result = official_cli(name, 'status')
        expect(result.stderr).to be_empty
        expect(result).to be_success
        expect(result.stdout).to include('Control repository:', 'Hiera repository:', File.realpath(hiera),
                                         'pre-commit: absent', 'no .pre-commit-config.yaml')
      end
    when 'sync'
      it 'uses merged config and inherited PATH and preserves rsync arguments, exits and signals' do
        binary = File.join(@directory, 'tools')
        FileUtils.mkdir_p(binary)
        stub = File.join(binary, 'rsync')
        File.write(stub, <<~RUBY)
          #!#{RbConfig.ruby}
          require 'json'
          puts JSON.generate(ARGV)
          Process.kill('TERM', Process.pid) if ENV['FIXTURE_SIGNAL']
          exit Integer(ENV.fetch('FIXTURE_STATUS', '0'))
        RUBY
        File.chmod(0o755, stub)
        config = { 'targets' => [{ 'source' => 'source with spaces/', 'destination' => 'target with spaces/' }] }
        configure_addon(name: name, extra: { 'addons' => { name => { 'config' => config } } })
        env = { 'PATH' => [binary, ENV.fetch('PATH')].join(File::PATH_SEPARATOR) }
        result = official_cli(name, '--dry-run', environment: env)
        expect(result).to be_success
        arguments = JSON.parse(result.stdout.lines.find { |line| line.start_with?('[') })
        expect(arguments).to eq(['-a', '--exclude=.git/', '--dry-run', '--',
                                 File.join(addon_project, 'source with spaces/'),
                                 File.join(addon_project, 'target with spaces/')])
        expect(official_cli(name, environment: env.merge('FIXTURE_STATUS' => '23')).exit_status).to eq(23)
        expect(official_cli(name, environment: env.merge('FIXTURE_SIGNAL' => '1')).exit_status).to eq(143)
      end
    end
  end
end
