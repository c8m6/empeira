# frozen_string_literal: true

module Empeira
  module Network
    module Peer
      # Control is private and token-bound. The packet stream never carries application configuration.
      class Channel
        def initialize(context:, runner:, record:)
          @runner = runner
          @token = record.fetch('peer').fetch('token')
          paths = [context.locations.temporary, context.locations.home].map { |root| root.join("ep-#{@token[0, 24]}") }
          @directory = paths.find { |path| path.join('ethernet.sock').to_s.bytesize < 100 }
          raise Error, 'No short private path is available for the peer packet channel' unless @directory
        end

        def socket
          @directory.join('ethernet.sock').to_s
        end

        def prepare
          FileUtils.mkdir_p(@directory, mode: 0o700)
          verify_directory
          raise Error, 'Peer channel is still active; stop its owning VM before retrying' if live?

          %w[control.sock ethernet.sock].each { |name| remove_socket(@directory.join(name)) }
        end

        def start(command)
          launch(command)
          Timeout.timeout(10) do
            loop do
              return if healthy?

              sleep 0.1
            end
          end
        rescue Timeout::Error
          raise Error, 'Peer packet channel did not become ready; inspect adapter/runtime availability'
        end

        def healthy?
          reply = request('status')
          reply['token'] == @token && reply['running'] == true
        rescue SystemCallError, IOError, Timeout::Error, JSON::ParserError
          false
        end

        def stop
          return unless @directory.exist?

          verify_directory
          if live?
            reply = request('stop')
            raise Providers::OwnershipError, 'Peer channel ownership changed' unless reply['token'] == @token

            Timeout.timeout(15) { sleep 0.1 while live? }
          end
          %w[control.sock ethernet.sock].each { |name| remove_socket(@directory.join(name)) }
        rescue SystemCallError, Timeout::Error
          raise Error, 'Peer channel shutdown is uncertain; resources retained for recovery', cause: nil
        end

        def destroy
          stop
          FileUtils.remove_entry_secure(@directory) if @directory.exist?
        end

        private

        def launch(command)
          config = @directory.join('channel.json')
          File.write(config, JSON.generate('token' => @token, 'command' => command), mode: 'w', perm: 0o600)
          helper = Pathname(__dir__).join('../../../../resources/network/channel.rb').realpath
          result = @runner.run(RbConfig.ruby, arguments: [helper.to_s, config.to_s], timeout: 10)
          raise Error, 'Cannot launch peer packet channel' unless result.success?
        end

        def request(operation)
          Timeout.timeout(2) do
            UNIXSocket.open(@directory.join('control.sock')) do |connection|
              connection.puts(JSON.generate('token' => @token, 'operation' => operation))
              JSON.parse(connection.gets(4096))
            end
          end
        end

        def live?
          path = @directory.join('channel.pid')
          return false unless path.file?

          Process.kill(0, Integer(path.read))
          true
        rescue Errno::ESRCH
          false
        end

        def verify_directory
          metadata = @directory.lstat
          unless metadata.directory? && metadata.uid == Process.uid && metadata.mode.nobits?(0o077)
            raise Providers::OwnershipError, 'Peer channel directory is not private to its owner'
          end

          verify_saved_token
        end

        def verify_saved_token
          path = @directory.join('channel.json')
          return unless path.exist? || path.symlink?

          metadata = path.lstat
          unless private_file?(metadata) && JSON.parse(path.read)['token'] == @token
            raise Providers::OwnershipError, 'Peer channel ownership token changed; cleanup refused'
          end
        rescue JSON::ParserError
          raise Providers::OwnershipError, 'Invalid peer channel ownership file', cause: nil
        end

        def private_file?(metadata)
          metadata.file? && metadata.uid == Process.uid && metadata.mode.nobits?(0o077)
        end

        def remove_socket(path)
          return unless path.exist? || path.symlink?
          unless path.lstat.socket? && path.lstat.uid == Process.uid
            raise Providers::OwnershipError, 'Unexpected file at the peer socket path'
          end

          File.unlink(path)
        end
      end
    end
  end
end
