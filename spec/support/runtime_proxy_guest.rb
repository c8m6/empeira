# frozen_string_literal: true

require_relative '../../resources/nodes/runtime_proxy'

module RuntimeProxyFixture
  def runtime_proxy_result(arguments, hostname)
    return unless arguments.first(2) == [Empeira::Node::Certificates::RUBY, '-e'] &&
                  arguments[2]&.include?('class RuntimeProxyGuest')

    @proxy_guest_roots ||= {}
    root = @proxy_guest_roots[hostname] ||= Pathname(Dir.mktmpdir('proxy-guest-'))
    apt = root.join('etc/apt/apt.conf.d')
    apt.mkpath
    changed = Empeira::RuntimeProxyGuest.new(JSON.parse(arguments.fetch(3)), root: root).reconcile
    Empeira::Execution::Result.new(stdout: JSON.generate('changed' => changed), stderr: '',
                                   exit_status: 0, timed_out: false)
  end

  def cleanup_runtime_proxy_guests
    @proxy_guest_roots&.each_value { |root| FileUtils.remove_entry(root) }
  end
end
