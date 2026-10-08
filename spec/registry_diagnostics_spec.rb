# frozen_string_literal: true

RSpec.describe 'Native registry error diagnostics' do
  %w[docker podman].each do |engine|
    context engine do
      let(:error_class) { Empeira::Providers::ExecutionError }
      let(:context) { Empeira::Application.new(project_path: @directory).context }
      let(:runner) { instance_double(Empeira::Execution::Runner) }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: context, runner: runner) }
      let(:image) do
        Empeira::Images::Configuration.reference({ 'repository' => 'library/postgres', 'tag' => '16' },
                                                 registry: 'cache.example:5000')
      end

      def failure(text, timed_out: false)
        allow(runner).to receive(:run) do |_, arguments:, **|
          local_manifest = [%w[manifest create], %w[manifest rm]].include?(arguments.take(2))
          Empeira::Execution::Result.new(stdout: local_manifest ? 'c' * 64 : '',
                                         stderr: local_manifest ? '' : text,
                                         exit_status: local_manifest ? 0 : 1, timed_out: !local_manifest && timed_out)
        end
      end

      %i[ensure_image remote_digest].each do |operation|
        ['401 Unauthorized', '403 Forbidden', 'unauthorized', 'authentication required', 'denied',
         'requested access to the resource is denied', 'insufficient_scope',
         'no basic auth credentials'].each do |diagnostic|
          it "adds a native login hint for #{operation} reporting #{diagnostic}" do
            failure(diagnostic)
            expect { runtime.public_send(operation, image) }.to raise_error(error_class) do |error|
              expect(error.message).to include('Registry authentication or authorization failed for cache.example:5000',
                                               "#{engine} login cache.example:5000")
              expect(error.message).not_to include('login docker.io')
            end
          end
        end

        {
          'manifest unknown' => 'image or tag', 'name unknown' => 'image or tag', 'not found' => 'image or tag',
          'connection refused' => 'network access', 'network unreachable' => 'network access',
          'DNS failure' => 'network access', 'certificate verify failed' => 'TLS verification',
          'x509: certificate signed by unknown authority' => 'TLS verification'
        }.each do |diagnostic, kind|
          it "keeps #{operation} #{diagnostic} distinct from authentication failure" do
            failure(diagnostic)
            expect { runtime.public_send(operation, image) }.to raise_error(error_class) do |error|
              expect(error.message).to include(kind)
              expect(error.message).not_to include(' login ')
            end
          end
        end

        it "does not offer login for #{operation} timeout or local socket permission errors" do
          failure('', timed_out: true)
          expect { runtime.public_send(operation, image) }.to raise_error(error_class) do |error|
            expect(error.message).to include('network access')
            expect(error.message).not_to include(' login ')
          end
          failure('permission denied: cannot connect to runtime socket')
          expect { runtime.public_send(operation, image) }.to raise_error(error_class) do |error|
            expect(error.message).not_to include(' login ')
          end
        end
      end

      it 'uses an explicit GHCR host and redacts secret material in runtime output' do
        failure("unauthorized: https://user:synthetic-password@ghcr.io/path?token=synthetic-token\n" \
                "Error: docker://user:synthetic-password@ghcr.io/private\n" \
                "Error: Bearer synthetic-bearer\nError: Basic synthetic-basic\n" \
                "Proxy-Authorization: Basic synthetic-proxy\nError: registry_token=synthetic-registry-token\n")
        expect { runtime.remote_digest('ghcr.io/example/image:1') }
          .to raise_error(error_class) do |error|
            expect(error.message).to include("#{engine} login ghcr.io", '[REDACTED')
            expect(error.message).not_to include('synthetic-', 'user:', 'Proxy-Authorization')
          end
      end
    end
  end

  it 'derives Docker Hub for exact short references and preserves explicit registry ports' do
    expect(Empeira::Images::Reference.host('ubuntu:24.04')).to eq('docker.io')
    expect(Empeira::Images::Reference.host('library/ubuntu:24.04')).to eq('docker.io')
    expect(Empeira::Images::Reference.host('localhost:5000/library/ubuntu:24.04')).to eq('localhost:5000')
  end
end
