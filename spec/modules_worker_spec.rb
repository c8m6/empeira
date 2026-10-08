# frozen_string_literal: true

require_relative 'support/module_source'

RSpec.describe 'Puppetfile installer contract' do
  let(:source) { ModuleSource.new(@directory).start }
  let(:work) { Pathname(@directory).join('work') }

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Execute the actual worker with isolated synthetic inputs.
  def install(content, overrides: [])
    work.mkpath
    work.join('Puppetfile').write(content)
    work.join('sources').mkpath
    work.join('request.json').write(JSON.generate('overrides' => overrides,
                                                  'sources' => work.join('sources').to_s,
                                                  'cache' => work.join('cache').to_s))
    worker = File.expand_path('../resources/modules/worker.rb', __dir__)
    environment = { 'HOME' => work.to_s, 'http_proxy' => '', 'https_proxy' => '',
                    'HTTP_PROXY' => '', 'HTTPS_PROXY' => '', 'GIT_ALLOW_PROTOCOL' => 'file' }
    runner = Empeira::Execution::Runner.new
    plan = runner.run(RbConfig.ruby, arguments: [worker, work.to_s, 'plan'], timeout: 30, environment: environment)
    return plan unless plan.success?

    sources = work.join('sources')
    sources.mkpath
    entries = JSON.parse(work.join('git-sources.json').read).fetch('git')
    acquired = Empeira::Modules::HostGit.new(runner: runner, project: Pathname(@directory)).prepare(entries,
                                                                                                    directory: sources)
    work.join('acquired.json').write(JSON.generate(acquired))
    runner.run(RbConfig.ruby, arguments: [worker, work.to_s, 'sync'], timeout: 30, environment: environment)
  end

  after { source.close }

  %w[ref branch tag commit].each do |selector|
    it "installs a real Git module selected by #{selector}" do
      ref = { 'ref' => 'v1', 'branch' => 'fixture', 'tag' => 'v1', 'commit' => source.commit }.fetch(selector)
      result = install("mod 'fixture/profile', git: '#{source.url}/fixture.git', #{selector}: '#{ref}'")
      expect(result.stderr).to eq('')
      expect(result).to be_success
      expect(work.join('modules/profile/value.txt').read).to eq('synthetic Git module')
    end
  end

  it 'evaluates Puppetfile Ruby exactly once before acquiring any module' do
    marker = work.join('evaluated')
    content = "raise 'evaluated twice' if File.exist?(#{marker.to_s.inspect})\n" \
              "File.write(#{marker.to_s.inspect}, 'once')\n" \
              "mod 'profile', git: '#{source.url}/fixture.git', ref: 'v1'"
    expect(install(content)).to be_success
    expect(marker.read).to eq('once')
  end

  it 'uses the acquired remote HEAD when no Git ref is specified' do
    result = install("mod 'profile', git: '#{source.url}/fixture.git'")
    expect(result).to be_success
    expect(work.join('modules/profile/value.txt').read).to eq('synthetic Git module')
  end

  it 'installs and checksum-verifies a synthetic Forge release alongside a Git module' do
    result = install("forge '#{source.url}'\nmod 'fixture-sample', '1.0.0'\n" \
                     "mod 'profile', git: '#{source.url}/fixture.git', tag: 'v1'")
    expect(result.stderr).to eq('')
    expect(result).to be_success
    expect(work.join('modules/sample/manifests/init.pp').read).to eq('class sample {}')
    expect(JSON.parse(work.join('git-sources.json').read).fetch('names')).to eq(%w[profile sample])
  end

  it 'excludes normalized local overrides before any fetch, including otherwise unusable SSH entries' do
    content = "mod 'owner-hieradata', git: 'ssh://unreachable.invalid/data'\n" \
              "mod 'owner/site_data', git: 'https://unreachable.invalid/data', ref: 'missing'\n" \
              "mod 'profile', git: '#{source.url}/fixture.git', tag: 'v1'"
    result = install(content, overrides: %w[hieradata site_data])
    expect(result).to be_success
    expect(work.join('Puppetfile').read).to eq(content)
    expect(JSON.parse(work.join('git-sources.json').read).fetch('names')).to eq(['profile'])
    expect(source.requests).to all(start_with('/fixture.git/'))
    expect(result.stdout).to include('EMPEIRA_MODULE_DONE:profile')
    expect(result.stdout).not_to include('EMPEIRA_MODULE_DONE:hieradata')
  end

  it 'rejects duplicate normalized names even when overridden' do
    result = install("mod 'owner-data', '1.0.0'\nmod 'other/data', '2.0.0'", overrides: ['data'])
    expect(result).not_to be_success
    expect(result.stderr).to include('duplicate normalized names')
  end

  it 'reports a missing Git ref when a Git ref does not exist' do
    result = install("mod 'profile', git: '#{source.url}/fixture.git', ref: 'does-not-exist'")
    expect(result).not_to be_success
    expect(result.stderr).to include('profile: cannot synchronize Git repository/ref')
  end

  it 'rejects syntax errors and custom install paths' do
    expect(install('mod (').stderr).to include('Invalid Puppetfile')
    expect(install("moduledir '../escape'\nmod 'fixture-sample', '1.0.0'").stderr).to include('normal environment')
  end

  it 'reuses native r10k and Git artifacts and updates an existing module after a ref change' do
    content = "mod 'profile', git: '#{source.url}/fixture.git', ref: 'fixture'"
    expect(install(content)).to be_success
    git_directory = work.join('modules/profile/.git')
    inode = git_directory.stat.ino
    cache_entries = work.join('cache').children
    expect(install(content)).to be_success
    expect(git_directory.stat.ino).to eq(inode)
    expect(work.join('cache').children).to eq(cache_entries)
    File.write(File.join(@directory, 'source/value.txt'), 'updated content')
    source.git('-C', File.join(@directory, 'source'), 'add', 'value.txt')
    source.git('-C', File.join(@directory, 'source'), '-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid',
               'commit', '--quiet', '-m', 'Updated fixture')
    source.git('-C', File.join(@directory, 'source'), 'update-server-info')
    expect(install(content)).to be_success
    expect(work.join('modules/profile/value.txt').read).to eq('updated content')
    expect(git_directory.stat.ino).to eq(inode)
    expect(install(content.sub("ref: 'fixture'", "ref: 'v1'"))).to be_success
    expect(work.join('modules/profile/value.txt').read).to eq('synthetic Git module')
  end

  it 'reuses an unchanged Forge module without downloading its archive again' do
    content = "forge '#{source.url}'\nmod 'fixture-sample', '1.0.0'"
    expect(install(content)).to be_success
    before = source.requests.count { |path| path.end_with?('.tar.gz') }
    expect(install(content)).to be_success
    expect(source.requests.count { |path| path.end_with?('.tar.gz') }).to eq(before)
  end

  it 'preserves useful missing Forge module diagnostics after filtering' do
    result = install("forge '#{source.url}'\nmod 'fixture-missing', '1.0.0'")
    expect(result).not_to be_success
    diagnostic = Empeira::Execution::Diagnostics.clean(result.stderr)
    expect(diagnostic).to include('Module missing', 'does not exist')
    expect(diagnostic).not_to include(source.url)
    expect(result.stdout).to include("EMPEIRA_MODULE_START:missing\n")
  end
end
