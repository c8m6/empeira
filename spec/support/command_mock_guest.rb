# frozen_string_literal: true

module CommandMockGuest
  def mock_definition
    { 'path' => File.join(@directory, 'mock-bin', 'oc'), 'mock_to' => 'echo', 'exit_code' => 0 }
  end

  def mock_context(commands)
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('mocks' => { 'commands' => commands }))
    app.context.with(configuration: Empeira::Configuration::Loader.new(project_path: @directory).load)
  end

  def execute_guest_mocks(transport, operation)
    allow(transport).to receive(operation).and_wrap_original do |method, target, arguments, **options|
      if arguments.first(2) == [Empeira::Node::Certificates::RUBY, '-e'] && arguments.size == 4
        app.runner.run(RbConfig.ruby, arguments: arguments.drop(1))
      else
        method.call(target, arguments, **options)
      end
    end
  end
end
