# frozen_string_literal: true

require_relative 'support/node_access'

RSpec.describe LiveNodeAccess, :files_only do
  include described_class

  it 'preserves command output between consecutive BEL and ST terminated shell markers' do
    output = "\e]0;synthetic shell\a\e]3008;start=fixture\e\\/dev/pts/1" \
             "\e]3008;end=fixture\e\\\r\nsynthetic-user\r\n" \
             "\e]3008;start=next\e\\connection=local\r\n\e]3008;end=next\e\\"
    expect(clean_session_output(output)).to eq("/dev/pts/1\nsynthetic-user\nconnection=local\n")
  end
end
