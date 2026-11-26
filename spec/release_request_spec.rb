# frozen_string_literal: true

require 'json'

RSpec.describe 'Owner release request', :files_only do
  let(:tag) { 'v1.2.3-alpha.1' }
  let(:body) { { 'tag' => tag, 'channel' => 'alpha', 'dry_run' => false } }
  let(:event) do
    { 'action' => 'opened', 'repository' => { 'full_name' => 'c8m6/empeira' },
      'sender' => { 'id' => 35_730_763 },
      'issue' => { 'title' => "Release request: #{tag}", 'body' => JSON.generate(body),
                   'author_association' => 'OWNER', 'user' => { 'id' => 35_730_763 } } }
  end

  it 'writes only validated release inputs for the owner on main' do
    result, output = run_request
    expect(result).to be_success, result.stderr
    expect(output).to eq("tag=#{tag}\nchannel=alpha\ndry_run=false\n")
  end

  it 'rejects non-owner authors, senders, edits and non-main refs' do
    event['issue']['user']['id'] = 1
    expect(run_request.first).not_to be_success
    event['issue']['user']['id'] = 35_730_763
    event['sender']['id'] = 1
    expect(run_request.first).not_to be_success
    event['sender']['id'] = 35_730_763
    event['action'] = 'edited'
    expect(run_request.first).not_to be_success
    event['action'] = 'opened'
    expect(run_request(ref: 'refs/heads/other').first).not_to be_success
  end

  it 'rejects mismatched titles, malformed or extra inputs and non-boolean dry runs' do
    event['issue']['title'] = 'Release request: v9.9.9'
    expect(run_request.first).not_to be_success
    event['issue']['title'] = "Release request: #{tag}"
    ['not JSON', JSON.generate(body.merge('channel' => 'stable')),
     JSON.generate(body.merge('dry_run' => 'false')), JSON.generate(body.merge('extra' => true))].each do |invalid|
      event['issue']['body'] = invalid
      result, output = run_request
      expect(result).not_to be_success
      expect(output).to be_empty
    end
  end

  def run_request(ref: 'refs/heads/main')
    payload = File.join(@directory, 'event.json')
    output = File.join(@directory, 'outputs')
    File.write(payload, JSON.generate(event))
    File.write(output, '')
    script = File.expand_path('../script/release_request.rb', __dir__)
    result = Empeira::Execution::Runner.new.run(
      RbConfig.ruby, arguments: [script],
      environment: { 'GITHUB_EVENT_PATH' => payload, 'GITHUB_OUTPUT' => output, 'GITHUB_REF' => ref,
                     'RUBYOPT' => nil, 'RUBYLIB' => nil }
    )
    [result, File.read(output)]
  end
end
