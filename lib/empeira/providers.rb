# frozen_string_literal: true

# rubocop:disable Lint/UnusedBlockArgument -- Factories share explicit composition dependencies.

module Empeira
  module Runtime
    CATALOG = Providers::Registry.new(
      'podman' => ->(**dependencies) { Podman.new(**dependencies) },
      'docker' => ->(**dependencies) { Docker.new(**dependencies) }
    ).freeze

    def self.registry
      CATALOG
    end
  end

  module VM
    CATALOG = Providers::Registry.new(
      'qemu' => ->(**dependencies) { Qemu.new(**dependencies) }
    ).freeze

    def self.registry
      CATALOG
    end
  end

  module Node
    CATALOG = Providers::Registry.new(
      'container' => lambda { |context:, runner:, runtimes:, engines:, build_info:, progress:|
        runtime = runtimes.build(context.container_engine, context: context, runner: runner)
        Container.new(context: context, runner: runner, backend: runtime, build_info: build_info, progress: progress)
      },
      'vm' => lambda { |context:, runner:, runtimes:, engines:, build_info:, progress:|
        engine = engines.build('qemu', context: context, runner: runner)
        runtime = runtimes.build(context.container_engine, context: context, runner: runner)
        VM.new(context: context, runner: runner, backend: engine, runtime: runtime,
               build_info: build_info, progress: progress)
      }
    ).freeze

    def self.registry
      CATALOG
    end
  end

  module Images
    CATALOG = Providers::Registry.new('upstream' => -> { Source.new }, 'custom' => -> { Source.new }).freeze

    def self.registry
      CATALOG
    end
  end
end

# rubocop:enable Lint/UnusedBlockArgument
