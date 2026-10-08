# frozen_string_literal: true

require 'net/http'

RSpec.describe Empeira::ControlPlane::Browser do
  let(:context) { Empeira::Application.new(project_path: @directory).context }
  let(:plan) { Empeira::ControlPlane::Plan.new(context: context) }

  it 'uses the configured browser image, ephemeral profile, internal DNS and no browser egress or host ports' do
    browser = described_class.new(plan).definitions(dns: '172.20.0.2').fetch('browser')
    selected = Empeira::Images::Configuration.reference(context.configuration.dig('browser', 'image'))
    expect(browser.options).to include('image' => selected,
                                       'network' => plan.network, 'dns' => '172.20.0.2', 'shm_size' => '1g')
    expect(browser.options.fetch('mounts')).to eq(['type=tmpfs,dst=/config'])
    expect(browser.options).not_to have_key('ports')
    expect(browser.options.fetch('environment')).to include('HTTP_PROXY' => '', 'HTTPS_PROXY' => '', 'ALL_PROXY' => '')
    expect(browser.options.fetch('environment')).to include('CHROME_CLI' => 'about:blank')
  end

  it 'passes the start URL unchanged in one environment argument without shell or network evaluation' do
    url = 'http://unavailable.empeira.internal:5000/?query=$(echo marker)&literal=`echo value` ; fragment'
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('browser' => { 'start_url' => url }))
    configured = plan
    expect(Net::HTTP).not_to receive(:new)
    expect(TCPSocket).not_to receive(:new)
    expect(Empeira::Execution::Runner).not_to receive(:new)
    definition = described_class.new(configured).definitions.fetch('browser')
    expect(definition.options.fetch('environment').fetch('CHROME_CLI')).to eq(url)
    arguments = Empeira::Runtime::ServiceArguments.new(definition).build
    expect(arguments.count("CHROME_CLI=#{url}")).to eq(1)
    expect(arguments[arguments.index("CHROME_CLI=#{url}") - 1]).to eq('--env')
    expect(definition.options.keys & %w[command entrypoint]).to be_empty
  end

  it 'fingerprints the start URL only in the browser service' do
    first = described_class.new(plan).definitions
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('browser' => { 'start_url' => 'http://openvoxview.empeira.internal:5000' }))
    changed = Empeira::ControlPlane::Plan.new(context: Empeira::Application.new(project_path: @directory).context)
    second = described_class.new(changed).definitions
    expect(first.fetch('browser').fingerprint).not_to eq(second.fetch('browser').fingerprint)
    expect(first.fetch('browser-ui').fingerprint).to eq(second.fetch('browser-ui').fingerprint)
  end

  it 'binds the browser address file without fingerprinting observed DNS addresses' do
    browser = described_class.new(plan)
    first = browser.definitions(dns: '172.20.0.2').fetch('browser-ui')
    second = browser.definitions(dns: '172.20.0.3').fetch('browser-ui')
    expect(first.options).not_to have_key('runtime_environment')
    expect(first.options.fetch('mounts')).to include(
      a_string_ending_with('dst=/empeira-browser/address,readonly')
    )
    expect(first.fingerprint).to eq(second.fingerprint)
    metadata = Empeira::Infrastructure::Definition.new(context: context).safe_options(first)
    expect(metadata).not_to have_key('runtime_environment')
    arguments = Empeira::Runtime::ServiceArguments.new(first).build
    expect(arguments).not_to include(a_string_starting_with('EMPEIRA_DNS_IP='))
  end

  it 'uses a provider-independent pinned local relay image' do
    first = described_class.new(plan).definitions.fetch('browser-ui')
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump({}))
    other = Empeira::ControlPlane::Plan.new(context: Empeira::Application.new(project_path: @directory).context)
    second = described_class.new(other).definitions.fetch('browser-ui')
    expect(first.options['image']).to eq(second.options['image'])
    recipe = first.options.fetch('recipe')
    source = Empeira::Images::Configuration.recipe(context.configuration.dig('images', 'relay'))
    expect(Empeira::Images::Recipe.bases(recipe)).to eq(Empeira::Images::Recipe.bases(source))
    expect(recipe).to include('USER 65534:65534')
    expect(first.options['image']).to eq(Empeira::Images::Configuration.local_image(recipe, purpose: 'relay'))
    expect(first.options['entrypoint']).to eq('ruby')
    expect(recipe).not_to match(/COPY|ADD|latest/)
  end

  it 'supports independent repository and tag overrides' do
    [{ 'repository' => 'internal.example:5000/browser' }, { 'tag' => 'private-version' }].each do |override|
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('browser' => { 'image' => override }))
      image = Empeira::Application.new(project_path: @directory).context.configuration.dig('browser', 'image')
      expect(image).to include(override)
      expect(image.keys).to match_array(%w[repository tag])
    end
  end

  %w[docker podman].each do |engine|
    it "uses the shared #{engine} contract for browser UI and additional services" do
      context_runner = Empeira::Execution::Runner.new
      runtime = Empeira::Runtime.registry.build(engine, context: context, runner: context_runner)
      definitions = described_class.new(plan).definitions(dns: '172.20.0.2')
      definitions['helper'] = Empeira::Services::Definition.new(
        key: 'helper', workspace: context.workspace, network: plan.network, dns: '172.20.0.2',
        image: 'example/helper:1', memory: 256, environment: { 'KEY' => 'value' }, command: ['serve']
      )
      definitions.each_value do |definition|
        arguments = Empeira::Runtime::ServiceArguments.new(definition).build
        result = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
        expect(context_runner).to receive(:run).with(engine, arguments: arguments, timeout: 30).and_return(result)
        allow(runtime).to receive(:inspect_service).with(definition).and_return({})
        runtime.create_service(definition)
        next unless definition.key == 'browser-ui'

        expect(arguments.each_index.filter_map { |index| arguments[index, 2] if arguments[index] == '--publish' })
          .to eq([['--publish', '127.0.0.1::3001/tcp']])
      end
    end
  end
end
