# frozen_string_literal: true

require_relative '../../resources/nodes/runtime_proxy'
require_relative '../../resources/nodes/interactive_tools'

module RuntimeProxyFixture
  def runtime_proxy_result(arguments, hostname)
    return unless arguments.first(2) == [Empeira::Node::Certificates::RUBY, '-e']

    klass = guest_settings_class(arguments[2])
    return unless klass

    root = guest_settings_root(hostname)
    prepare_tool_fixture(root) if klass == Empeira::InteractiveToolsGuest
    reconciled = klass.new(JSON.parse(arguments.fetch(3)), root: root).reconcile
    result = reconciled.is_a?(Hash) ? reconciled : { 'changed' => reconciled }
    Empeira::Execution::Result.new(stdout: JSON.generate(result), stderr: '',
                                   exit_status: 0, timed_out: false)
  end

  def guest_settings_root(hostname)
    @proxy_guest_roots ||= {}
    root = @proxy_guest_roots[hostname] ||= Pathname(Dir.mktmpdir('proxy-guest-'))
    root.join('etc/apt/apt.conf.d').mkpath
    root
  end

  def guest_settings_class(helper)
    return Empeira::RuntimeProxyGuest if helper&.include?('class RuntimeProxyGuest')
    return Empeira::InteractiveToolsGuest if helper&.include?('class InteractiveToolsGuest')

    nil
  end

  def prepare_tool_fixture(root)
    binary = root.join('opt/puppetlabs/bin')
    binary.mkpath
    %w[puppet facter].each do |name|
      binary.join(name).write("#!/bin/sh\nprintf 'synthetic-version\\n'\n")
      binary.join(name).chmod(0o755)
    end
    global = root.join('etc/bash.bashrc')
    global.write('# Synthetic global Bash configuration') unless global.exist?
  end

  def cleanup_runtime_proxy_guests
    @proxy_guest_roots&.each_value { |root| FileUtils.remove_entry(root) }
  end
end
