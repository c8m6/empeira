# frozen_string_literal: true

require 'empeira'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

module ProjectFixture
  def vm_guest(application)
    engine = Empeira::VM.registry.build('qemu', context: application.context, runner: application.runner)
    qemu = Empeira::VM::QemuRuntime.new(engine: engine, context: application.context, runner: application.runner)
    Empeira::VM::Guest.new(context: application.context, runner: application.runner, qemu: qemu)
  end

  def initialize_project(directory)
    FileUtils.mkdir_p(directory)
    Empeira::Execution::Runner.new.run('git', arguments: ['init', '--quiet', directory.to_s])
    FileUtils.touch(File.join(directory, '.empeira.yaml'))
  end
end

RSpec.configure do |config|
  config.include ProjectFixture
  config.order = :random
  config.before do
    allow(Empeira::Platform::Locations).to receive(:new).and_wrap_original do |method, **options|
      method.call(home: File.join(@directory, 'user-home'), **options)
    end
  end
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.around do |example|
    credentials = %w[EMPEIRA_AGENT_REPO_USERNAME EMPEIRA_AGENT_REPO_PASSWORD].to_h { |key| [key, ENV.delete(key)] }
    Dir.mktmpdir('empeira-spec-') do |directory|
      @directory = directory
      user_home = File.join(directory, 'user-home')
      FileUtils.mkdir_p(user_home)
      initialize_project(directory)
      example.run
    end
  ensure
    credentials.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
