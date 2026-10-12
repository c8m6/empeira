# frozen_string_literal: true

require_relative 'support/addon_source'

RSpec.describe Empeira::Addons::Installation do
  include AddonFixture

  let(:source) { AddonSource.new(@directory).start }
  let(:entry) { addon_application.addons.installation('example') }
  before { configure_addon }
  after { source.close }

  it 'installs atomically, reuses commits, and never alters the control repository or starts infrastructure' do
    before = source.git('-C', addon_project, 'status', '--porcelain')
    expect(Empeira::Infrastructure::Service).not_to receive(:new)
    expect_any_instance_of(Empeira::Runtime::Container).not_to receive(:check_available!)
    expect(entry.local).to be_nil
    commit, path, = entry.synchronize
    expect(commit).to eq(source.commit)
    expect(path.to_s).to start_with(File.join(@directory, 'user-home/.empeira/addons/'))
    inode = path.stat.ino
    expect(entry.synchronize[1].stat.ino).to eq(inode)
    requests = source.requests.size
    expect(entry.synchronize(missing_only: true).first).to eq(commit)
    expect(source.requests.size).to eq(requests)
    expect(source.git('-C', addon_project, 'status', '--porcelain')).to eq(before)
  end

  %w[fixture v1 HEAD].each do |ref|
    it "resolves #{ref} with Puppetfile Git semantics" do
      configure_addon(ref: ref)
      expect(entry.synchronize.first).to eq(source.commit)
    end
  end

  it 'accepts full and abbreviated commit references' do
    [source.commit, source.commit[0, 10]].each do |ref|
      configure_addon(ref: ref)
      expect(addon_application.addons.installation('example').synchronize.first).to eq(source.commit)
    end
  end

  it 'keeps parallel revisions, refreshes branches, and reuses the original tagged commit' do
    original = entry.synchronize
    source.directory.join('README.md').write('revision two')
    source.commit_changes
    expect(entry.synchronize(missing_only: true).first).to eq(original.first)
    current = entry.synchronize
    expect(current.first).to eq(source.commit)
    expect(current[1]).not_to eq(original[1])
    expect(original[1].join('README.md').read).to include('Minimal')
    configure_addon(ref: 'v1')
    tagged = addon_application.addons.installation('example').synchronize
    expect(tagged[1]).to eq(original[1])
    expect(current[1]).to exist
  end

  it 'refreshes moved tags like the force-fetched Puppetfile host mirror' do
    configure_addon(ref: 'v1')
    original = entry.synchronize.first
    source.commit_changes
    source.git('-C', source.directory.to_s, 'tag', '--force', 'v1')
    source.git('-C', source.directory.to_s, 'update-server-info')
    expect(entry.synchronize.first).to eq(source.commit)
    expect(source.commit).not_to eq(original)
  end

  it 'shares the same source/ref under different logical names' do
    original = entry.synchronize
    configure_addon(name: 'git-hooks')
    expect(addon_application.addons.installation('git-hooks').synchronize[1]).to eq(original[1])
  end

  it 'separates equal names from different Git sources' do
    original = entry.synchronize
    second = AddonSource.new(File.join(@directory, 'other')).start
    configure_addon(url: "#{second.url}/fixture.git")
    other = addon_application.addons.installation('example').synchronize
    expect(other[1]).not_to eq(original[1])
    expect(original[1]).to exist
  ensure
    second&.close
  end

  it 'rejects unknown refs and failed downloads without publishing an installation' do
    configure_addon(ref: 'does-not-exist')
    expect { entry.synchronize }.to raise_error(Empeira::Addons::Error, /reference is unknown/)
    expect(entry.local).to be_nil
    configure_addon(url: "#{source.url}/missing.git")
    missing = addon_application.addons.installation('example')
    expect { missing.synchronize }.to raise_error(Empeira::Addons::Error, /Git source acquisition failed/)
    expect(missing.local).to be_nil
  end

  it 'keeps the previous valid version after a failed update' do
    original = entry.synchronize
    source.directory.join('empeira-addon.yaml').write('schema: 99')
    source.commit_changes
    expect { entry.synchronize }.to raise_error(Empeira::Addons::Error, /manifest/)
    expect(entry.local.first).to eq(original.first)
  end

  it 'cleans an interrupted publication and retries without trusting staging content' do
    allow(entry).to receive(:checkout).and_raise(Interrupt)
    expect { entry.synchronize }.to raise_error(Interrupt)
    expect(entry.local).to be_nil
    expect(Dir.glob(File.join(@directory, 'user-home/.empeira/addons/**/.staging-*'))).to be_empty
    allow(entry).to receive(:checkout).and_call_original
    expect(entry.synchronize.first).to eq(source.commit)
  end

  it 'materializes long paths and tracked files marked export-ignore without invoking filters' do
    long = source.directory.join(*(['nested-directory' * 4] * 5), 'data.txt')
    long.dirname.mkpath
    long.write('tracked data')
    source.directory.join('.gitattributes').write('empeira-addon.yaml export-ignore')
    source.commit_changes
    _, path, = entry.synchronize
    expect(path.join(long.relative_path_from(source.directory)).read).to eq('tracked data')
    expect(path.join('empeira-addon.yaml')).to be_file
    expect(path.join('.git')).not_to exist
  end

  it 'refuses a home-cache symlink into the control repository before writing anything there' do
    File.symlink(addon_project, File.join(@directory, 'user-home/.empeira'))
    expect { entry.synchronize }.to raise_error(Empeira::Addons::Error, /outside the control repository/)
    expect(File).not_to exist(File.join(addon_project, 'addons'))
  end

  it 'serializes concurrent installations from separate CLI processes' do
    results = 3.times.map { Thread.new { addon_cli('addons', 'sync') } }.map(&:value)
    expect(results.map(&:stderr)).to all(eq(''))
    expect(results).to all(be_success)
    expect(entry.local.first).to eq(source.commit)
    root = addon_application.context.locations.addons
    expect(root.glob('*/revisions/*').size).to eq(1)
  end

  it 'never executes addon files, Git hooks, filters, or submodule programs during synchronization' do
    marker = File.join(@directory, 'executed')
    source.script("File.write(#{marker.inspect}, 'addon executed')")
    source.directory.join('.gitattributes').write('* filter=unsafe')
    source.directory.join('.gitmodules').write("[submodule \"evil\"]\npath = dependency\nurl = ext::touch #{marker}\n")
    source.commit_changes
    hooks = Pathname(@directory).join('hooks')
    hooks.mkpath
    %w[post-checkout post-merge post-index-change reference-transaction].each do |hook|
      hooks.join(hook).write("#!/bin/sh\ntouch '#{marker}'\n")
      hooks.join(hook).chmod(0o755)
    end
    keys = { 'GIT_CONFIG_COUNT' => '3', 'GIT_CONFIG_KEY_0' => 'core.hooksPath', 'GIT_CONFIG_VALUE_0' => hooks.to_s,
             'GIT_CONFIG_KEY_1' => 'filter.unsafe.smudge', 'GIT_CONFIG_VALUE_1' => "touch '#{marker}'",
             'GIT_CONFIG_KEY_2' => 'filter.unsafe.required', 'GIT_CONFIG_VALUE_2' => 'true' }
    expect(addon_cli('addons', 'sync', environment: keys)).to be_success
    expect(File).not_to exist(marker)
  end

  it 'shows list/info status and runs updates with no infrastructure' do
    expect(addon_cli('addons', 'list').stdout).to include('example: missing')
    expect(addon_cli('addons', 'info', 'example').stdout).to include('Status: missing')
    result = addon_cli('addons', 'update')
    expect(result.stderr).to eq('')
    expect(result).to be_success
    expect(addon_cli('addons', 'list').stdout).to include('example: installed')
    expect(addon_cli('addons', 'info', 'example').stdout).to include(source.commit, 'schema: 1', 'Path:', source.url)
    expect(Dir.glob(File.join(@directory, 'user-home/**/workspaces'))).to be_empty
  end
end
