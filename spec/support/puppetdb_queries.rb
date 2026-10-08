# frozen_string_literal: true

module PuppetDBQueries
  # rubocop:disable-next Metrics/AbcSize -- Poll real asynchronous persistence with bounded failure diagnostics.
  def query_until(server, arguments, containing: '')
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    loop do
      result = runtime.service_exec(server, arguments)
      return result.stdout if result.success? && result.stdout.strip != '[]' && result.stdout.include?(containing)

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        diagnostic = Empeira::Execution::Diagnostics.clean(result.stderr)
        raise "PuppetDB did not persist the synthetic catalog/report (exit #{result.exit_status}): #{diagnostic}"
      end

      sleep 1
    end
  end
end
