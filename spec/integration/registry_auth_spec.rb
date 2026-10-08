# frozen_string_literal: true

require_relative '../support/image_registry'

RSpec.describe 'Native registry authentication', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:app) { Empeira::Application.new(project_path: @directory) }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }

      before do
        skip 'Set EMPEIRA_INTEGRATION=images for synthetic native registry authentication' unless
          ENV['EMPEIRA_INTEGRATION'] == 'images'

        runtime.check_available!
        @fixture = ImageRegistryFixture.new(runtime: runtime, runner: app.runner, directory: @directory,
                                            auth: true).start
        allow(app.runner).to receive(:run).and_wrap_original do |method, executable, arguments:, **options|
          method.call(executable, arguments: @fixture.arguments(arguments), **options,
                                  environment: @fixture.environment)
        end
      end

      after { @fixture&.close }

      it 'reports unauthenticated metadata/pulls and succeeds after native login without Empeira credentials' do
        @fixture.login
        @fixture.publish('private synthetic image')
        @fixture.forget_tag
        @fixture.logout
        %i[remote_digest ensure_image].each do |operation|
          expect { runtime.public_send(operation, @fixture.image) }
            .to raise_error(Empeira::Providers::ExecutionError) do |error|
              expect(error.message).to include("#{engine} login #{@fixture.host}")
              expect(error.message).not_to include('empeira-fixture-only', 'Authorization:')
            end
        end
        @fixture.login
        expect(runtime.remote_digest(@fixture.image)).to match(/\Asha256:[a-f0-9]{64}\z/)
        runtime.ensure_image(@fixture.image)
        expect(runtime.refresh_image(@fixture.image)).to eq(:unchanged)
        expect(Empeira::Infrastructure::Store.new(context: app.context).load).to be_nil
        expect(File.read(File.join(@directory, '.empeira.yaml'))).to be_empty
      end
    end
  end
end
