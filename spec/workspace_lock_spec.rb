# frozen_string_literal: true

RSpec.describe Empeira::Infrastructure::Store do
  def store(project = @directory)
    locations = Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {})
    described_class.new(context: Empeira::Application.new(project_path: project, locations: locations).context)
  end

  it 'excludes competing mutations and releases after success' do
    store.with_lock do
      expect do
        store.with_lock do
          raise 'must not enter'
        end
      end.to raise_error(Empeira::Infrastructure::Locked, /Wait and retry/)
    end
    expect { store.with_lock { true } }.not_to raise_error
  end

  it 'releases locks after exceptions and interrupts' do
    [RuntimeError, Interrupt].each do |error|
      expect { store.with_lock { raise error } }.to raise_error(error)
      expect { store.with_lock { true } }.not_to raise_error
    end
  end

  it 'does not serialize separate workspaces' do
    second = File.join(@directory, 'second')
    initialize_project(second)
    expect { store.with_lock { store(second).with_lock { true } } }.not_to raise_error
  end

  def child_lock(exit_immediately: false)
    code = <<~RUBY
      require 'empeira'
      user_home = File.join(ARGV[0], 'user-home')
      locations = Empeira::Platform::Locations.new(home: user_home, environment: {})
      context = Empeira::Application.new(project_path: ARGV[0], locations: locations).context
      begin
        Empeira::Infrastructure::Store.new(context: context).with_lock { #{exit_immediately ? 'exit! 0' : 'true'} }
      rescue Empeira::Infrastructure::Locked
        exit 9
      end
    RUBY
    Empeira::Execution::Runner.new.run(RbConfig.ruby,
                                       arguments: ['-I', File.expand_path('../lib', __dir__), '-e', code, @directory],
                                       timeout: 10)
  end

  it 'excludes another OS process and allows a later process after release' do
    store.with_lock { expect(child_lock.exit_status).to eq(9) }
    expect(child_lock).to be_success
  end

  it 'does not leave a stale lock after abrupt process exit without Ruby ensure blocks' do
    expect(child_lock(exit_immediately: true)).to be_success
    expect { store.with_lock { true } }.not_to raise_error
    expect(child_lock).to be_success
  end
end
