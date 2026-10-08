# frozen_string_literal: true

RSpec.describe 'Reviewed node image tools', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:app) { Empeira::Application.new(project_path: @directory) }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }

      before do
        skip 'Set EMPEIRA_INTEGRATION=node-tools for real image package checks' unless
          ENV['EMPEIRA_INTEGRATION'] == 'node-tools'
        runtime.check_available!
      rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
        raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

        skip e.message
      end

      after { runtime.remove_service(@definition) if @definition }

      [%w[ubuntu 22.04], %w[ubuntu 24.04], %w[rocky 8], %w[rocky 9]].each do |os, version|
        it "provides working sudo and file lookup on #{os} #{version}" do
          config = app.context.configuration
          request = Empeira::Node::RunRequest.from_config(hostname: 'tools', provider: 'container', config: config)
          image = Empeira::Node::Image.new(config: config, request: request.with(os: os, version: version),
                                           architecture: runtime.architecture)
          runtime.ensure_image(image.reference, recipe: image.recipe, files: image.build_files)
          @definition = Empeira::Services::Definition.new(
            key: 'tools', workspace: app.context.workspace, image: image.reference,
            network: 'none', memory: 256, init: 'process', entrypoint: 'sleep', command: ['infinity']
          )
          resource = runtime.create_service(@definition)
          runtime.start_service(resource)
          commands = [%w[sudo -n true], %w[mkdir /tool-fixture], %w[touch /tool-fixture/lookup-marker],
                      %w[updatedb --database-root /tool-fixture --output /tool-fixture/index.db --prunefs],
                      %w[locate --database /tool-fixture/index.db lookup-marker]]
          commands[-2] << ''
          results = commands.map { |arguments| runtime.service_exec(resource, arguments) }
          expect(results).to all(be_success)
          expect(results.last.stdout.strip).to eq('/tool-fixture/lookup-marker')
        end
      end

      [%w[ubuntu 24.04], %w[rocky 9], %w[almalinux 8], %w[almalinux 9],
       %w[oraclelinux 8]].each do |os, version|
        it "keeps managed agent installation out of the #{os} base image" do
          fragment = {}
          File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(fragment))
          current_app = Empeira::Application.new(project_path: @directory)
          config = current_app.context.configuration
          request = Empeira::Node::RunRequest.from_config(hostname: 'tools', provider: 'container', config: config)
          image = Empeira::Node::Image.new(config: config, request: request.with(os: os, version: version),
                                           architecture: runtime.architecture)
          runtime.ensure_image(image.reference, recipe: image.recipe, files: image.build_files)
          @definition = Empeira::Services::Definition.new(
            key: 'tools', workspace: current_app.context.workspace, image: image.reference,
            network: 'none', memory: 256, init: 'process', entrypoint: 'sleep', command: ['infinity']
          )
          resource = runtime.create_service(@definition)
          runtime.start_service(resource)
          expect(runtime.service_exec(resource, %w[sudo -n true])).to be_success
          expect(runtime.service_exec(resource, %w[test ! -e /opt/puppetlabs/bin/puppet])).to be_success
        end
      end
    end
  end
end
