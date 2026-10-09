# frozen_string_literal: true

require_relative '../script/ci_docker_mirror'

RSpec.describe CIDockerMirror do
  it 'preserves runner settings and existing mirrors when adding the public cache' do
    original = { 'features' => { 'containerd-snapshotter' => true }, 'debug' => false,
                 'registry-mirrors' => ['https://cache.example.test'] }
    configured = JSON.parse(described_class.configuration(JSON.generate(original)))
    expect(configured.except('registry-mirrors')).to eq(original.except('registry-mirrors'))
    expect(configured.fetch('registry-mirrors')).to eq([described_class::MIRROR, 'https://cache.example.test'])
    expect(described_class.configuration(JSON.generate(configured))).to eq(JSON.pretty_generate(configured))
  end

  it 'supports a fresh runner without daemon configuration' do
    path = File.join(@directory, 'missing-daemon.json')
    script = File.expand_path('../script/ci_docker_mirror.rb', __dir__)
    result = Empeira::Execution::Runner.new.run(RbConfig.ruby, arguments: [script, 'configure', path])
    expect(result).to be_success
    expect(JSON.parse(result.stdout)).to eq('registry-mirrors' => [described_class::MIRROR])
    expect(File.exist?(path)).to be(false)
  end

  it 'rejects malformed runner settings before producing replacement configuration' do
    expect { described_class.configuration('{') }.to raise_error(JSON::ParserError)
    ['[]', '{"registry-mirrors": null}', '{"registry-mirrors": [1]}'].each do |contents|
      expect { described_class.configuration(contents) }.to raise_error(ArgumentError)
    end
  end

  it 'requires the running daemon to report the cache after restart' do
    expect { described_class.verify!('["https://mirror.gcr.io/"]') }.not_to raise_error
    expect { described_class.verify!('["https://mirror.gcr.io", "https://cache.example.test"]') }.not_to raise_error
    ['[]', '["https://cache.example.test"]', '{}'].each do |contents|
      expect { described_class.verify!(contents) }.to raise_error(ArgumentError, /did not activate/)
    end
  end
end
