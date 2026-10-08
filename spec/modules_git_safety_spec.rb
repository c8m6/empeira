# frozen_string_literal: true

RSpec.describe Empeira::Modules::GitSafety do
  let(:project) { Pathname(@directory).realpath }
  let(:runner) { Empeira::Execution::Runner.new }
  let(:events) { [] }
  let(:progress) { Empeira::Progress.new(listener: ->(event) { events << event }) }
  let(:guard) { described_class.new(project: project, runner: runner, progress: progress) }

  def git(*arguments)
    result = runner.run('git', arguments: arguments, directory: project)
    expect(result).to be_success
    result
  end

  it 'quietly accepts a path ignored by Git without changing ignore files' do
    project.join('.gitignore').write("/modules/\n")
    guard.verify(project.join('modules'), recommend: true)
    expect(events).to be_empty
    expect(project.join('.gitignore').read).to eq("/modules/\n")
  end

  it 'recommends the repository-relative directory once without changing .gitignore' do
    2.times { guard.verify(project.join('.cache/puppet-modules'), recommend: true) }
    recommendation = 'Recommendation: .cache/puppet-modules/ is not ignored by Git. ' \
                     'Add /.cache/puppet-modules/ to .gitignore.'
    expect(events.map(&:message)).to eq([recommendation])
    expect(project.join('.gitignore')).not_to exist
  end

  it 'uses nested ignore rules and the configured global excludes file' do
    project.join('.cache').mkpath
    project.join('.cache/.gitignore').write("/nested/\n")
    guard.verify(project.join('.cache/nested'), recommend: true)
    project.join('global-ignore').write("global-modules/\n")
    git('config', 'core.excludesFile', project.join('global-ignore').to_s)
    guard.verify(project.join('global-modules'), recommend: true)
    expect(events).to be_empty
  end

  it 'does not consult repository Git rules for an external or externally resolved path' do
    Dir.mktmpdir('empeira-external-') do |external|
      File.symlink(external, project.join('external-link'))
      expect(runner).not_to receive(:run)
      guard.verify(Pathname(external).join('modules'), recommend: true)
      guard.verify(project.join('external-link/modules'), recommend: true)
      expect(events).to be_empty
    end
  end

  it 'rejects tracked contents even if Git ignore rules match' do
    project.join('modules/profile').mkpath
    project.join('modules/profile/init.pp').write('tracked code')
    git('add', 'modules')
    project.join('.gitignore').write("/modules/\n")
    expect { guard.verify(project.join('modules'), recommend: true) }
      .to raise_error(Empeira::Error, /Git-tracked files/)
    expect(project.join('modules/profile/init.pp').read).to eq('tracked code')
    expect(events).to be_empty
  end

  it 'does not interpret pathspec metacharacters as other managed paths' do
    project.join('other').write('tracked')
    git('add', 'other')
    guard.verify(project.join('[other]'), recommend: true)
    expect(events.size).to eq(1)
  end
end
