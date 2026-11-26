# frozen_string_literal: true

require 'json'
require_relative 'release_support'

# Parse the immutable issue-opened event, never interpolate issue text into shell.
event = JSON.parse(File.read(ENV.fetch('GITHUB_EVENT_PATH')))
issue = event.fetch('issue')
owner_id = 35_730_763
unless event.fetch('action') == 'opened' && event.dig('repository', 'full_name') == 'c8m6/empeira' &&
       issue['author_association'] == 'OWNER' && issue.dig('user', 'id') == owner_id &&
       event.dig('sender', 'id') == owner_id
  abort 'Release request must be opened by the repository owner'
end

abort 'Release requests must run on main' unless ENV.fetch('GITHUB_REF') == 'refs/heads/main'
request = JSON.parse(issue.fetch('body'))
unless request.is_a?(Hash) && request.keys.sort == %w[channel dry_run tag]
  abort 'Expected tag, channel and dry_run only'
end

tag, channel, dry_run = request.values_at('tag', 'channel', 'dry_run')
abort 'Expected string tag and channel' unless tag.is_a?(String) && channel.is_a?(String)
ReleaseSupport.validate!(tag, channel)
abort 'Issue title must match the requested tag' unless issue['title'] == "Release request: #{tag}"
abort 'dry_run must be a boolean' unless dry_run == true || dry_run == false

File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') do |out|
  out.puts "tag=#{tag}", "channel=#{channel}", "dry_run=#{dry_run}"
end
