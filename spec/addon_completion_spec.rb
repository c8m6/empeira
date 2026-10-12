# frozen_string_literal: true

require_relative 'support/addon_source'
require 'empeira/completion/catalog'
require 'empeira/completion/bash'

RSpec.describe 'Addon Bash completion' do
  include AddonFixture

  let(:source) { AddonSource.new(@directory).start }
  before do
    configure_addon
    addon_application.addons.synchronize
  end
  after { source.close }

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Exercise the generated adapter in a real Bash process.
  def complete(*words)
    script = File.join(@directory, 'completion.bash')
    File.write(script, Empeira::Completion::Bash.generate)
    executable = File.join(@directory, 'empeira-test')
    File.write(executable, <<~RUBY)
      #!#{RbConfig.ruby}
      require #{File.expand_path('support/isolated_cli_locations.rb', __dir__).inspect}
      load #{File.expand_path('../bin/empeira', __dir__).inspect}
    RUBY
    File.chmod(0o755, executable)
    code = 'source "$1"; executable="$2"; shift 2; COMP_WORDS=("$executable" "$@"); '
    code += 'COMP_CWORD=$((${#COMP_WORDS[@]} - 1)); _empeira_complete; '
    code += 'if ((${#COMPREPLY[@]})); then printf "%s\0" "${COMPREPLY[@]}"; fi'
    environment = { 'EMPEIRA_TEST_HOME' => File.join(@directory, 'user-home') }
    result = Empeira::Execution::Runner.new.run('bash', arguments: ['-c', code, 'spec', script, executable, *words],
                                                        environment: environment,
                                                        directory: addon_project, timeout: 15)
    expect(result.stderr).to eq('')
    expect(result).to be_success
    result.stdout.split("\0")
  end

  it 'completes configured names, management commands and info names through the real adapter' do
    expect(complete('addons', '')).to include('list', 'info', 'sync', 'update')
    expect(complete('addons', 'info', '')).to eq(['example'])
    expect(complete('addon', '')).to eq(['example'])
    expect(complete('addon', 'example', '')).to contain_exactly('echo', 'directory', 'choose', 'plain')
    expect(complete('--container-engine', 'docker', 'addon', 'example', 'ec')).to eq(['echo'])
  end

  it 'completes enum arguments, options and fixed option values' do
    expect(complete('addon', 'example', 'choose', 's')).to eq(['second'])
    expect(complete('addon', 'example', 'echo', '--f')).to eq(['--format'])
    expect(complete('addon', 'example', 'echo', '--format', '')).to eq(%w[yaml text])
    expect(complete('addon', 'example', 'echo', '--format=y')).to eq(['--format=yaml'])
    expect(complete('addon', 'example', 'echo', '--format', '=', 't')).to eq(['text'])
    expect(complete('addon', 'example', 'plain', '')).to be_empty
  end

  it 'uses native Bash completion for relative, absolute, nested and special-character paths' do
    FileUtils.mkdir_p(File.join(addon_project, 'files/sub directory'))
    ['a file.xml', 'a[$]file.xml', "a'quote.xml"].each do |name|
      File.write(File.join(addon_project, 'files', name), '')
    end
    expected = ['files/a file.xml', 'files/a[$]file.xml', "files/a'quote.xml"]
    expect(complete('addon', 'example', 'echo', 'files/a')).to match_array(expected)
    absolute = File.join(addon_project, 'files/a')
    expect(complete('addon', 'example', 'echo', absolute)).to match_array(expected.map { |path|
      File.join(addon_project, path)
    })
    File.write(File.join(addon_project, 'files/sub directory/deep.xml'), '')
    expect(complete('addon', 'example', 'echo', 'files/sub directory/d')).to eq(['files/sub directory/deep.xml'])
    expect(complete('addon', 'example', 'echo', 'files/sub\ directory/d')).to eq(['files/sub directory/deep.xml'])
    expect(complete('addon', 'example', 'echo', '"files/sub directory/d')).to eq(['files/sub directory/deep.xml'])
    expect(complete('addon', 'example', 'echo', "'files/sub directory/d")).to eq(['files/sub directory/deep.xml'])
    expect(complete('addon', 'example', 'echo', 'input.xml', 'files/a')).to match_array(expected)
  end

  it 'distinguishes directories and handles option path values without consuming positional arguments' do
    FileUtils.mkdir_p(File.join(addon_project, 'paths/a directory'))
    File.write(File.join(addon_project, 'paths/a file'), '')
    expect(complete('addon', 'example', 'directory', 'paths/a')).to eq(['paths/a directory'])
    expect(complete('addon', 'example', 'echo', '--directory', 'paths/a')).to eq(['paths/a directory'])
    expect(complete('addon', 'example', 'echo', '--input',
                    'paths/a')).to contain_exactly('paths/a directory', 'paths/a file')
    expect(complete('addon', 'example', 'echo',
                    '--input=paths/a')).to contain_exactly('--input=paths/a directory', '--input=paths/a file')
    expect(complete('addon', 'example', 'echo', '--verbose', '--format', 'text', 'paths/a')).to include('paths/a file')
    expect(complete('addon', 'example', 'echo', '--', 'paths/a')).to include('paths/a file')
  end

  it 'preserves embedded newlines and leading hyphens without word splitting' do
    File.write(File.join(addon_project, "line\nbreak.xml"), '')
    File.write(File.join(addon_project, '-option.xml'), '')
    expect(complete('addon', 'example', 'echo', "line\nb")).to eq(["line\nbreak.xml"])
    expect(complete('addon', 'example', 'echo', 'line')).to eq(["line\nbreak.xml"])
    expect(complete('addon', 'example', 'echo', '--', '-op')).to eq(['-option.xml'])
  end

  it 'never executes addon code or synchronizes during completion, and ignores invalid manifests' do
    _, path, = addon_application.addons.installation('example').local
    marker = File.join(@directory, 'executed')
    path.join('bin/example').write("#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'executed')\n")
    count = source.requests.size
    expect(complete('addon', 'example', '')).to include('echo')
    expect(File).not_to exist(marker)
    expect(source.requests.size).to eq(count)
    path.join('empeira-addon.yaml').write('schema: 999')
    expect(complete('addon', 'example', '')).to be_empty
    expect(complete('node', 'r')).to eq(['run'])
    expect(complete('addon', 'missing', '')).to be_empty
  end

  it 'offers configured missing names without downloading them' do
    configure_addon(name: 'missing', ref: 'different')
    count = source.requests.size
    expect(complete('addon', '')).to eq(['missing'])
    expect(complete('addon', 'missing', '')).to be_empty
    expect(source.requests.size).to eq(count)
  end
end
