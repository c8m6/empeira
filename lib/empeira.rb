# frozen_string_literal: true

require_relative 'empeira/compatibility/data'
require_relative 'empeira/errors'

# Register code without loading providers, networking or guest tooling for CLI help.
module Empeira
  autoload :Application, "#{__dir__}/empeira/application"
  autoload :BuildInfo, "#{__dir__}/empeira/build_info"
  autoload :HostnamePattern, "#{__dir__}/empeira/hostname_pattern"
  autoload :Immutable, "#{__dir__}/empeira/immutable"
  autoload :Progress, "#{__dir__}/empeira/progress"
  autoload :ProjectRoot, "#{__dir__}/empeira/project_root"
  autoload :VersionRequirement, "#{__dir__}/empeira/version_requirement"
  autoload :Workspace, "#{__dir__}/empeira/workspace"

  module Addons
    autoload :Environment, "#{__dir__}/empeira/addons/environment"
    autoload :Error, "#{__dir__}/empeira/addons/error"
    autoload :Installation, "#{__dir__}/empeira/addons/installation"
    autoload :Manifest, "#{__dir__}/empeira/addons/manifest"
    autoload :Service, "#{__dir__}/empeira/addons/service"
    autoload :Storage, "#{__dir__}/empeira/addons/storage"
  end

  module Agent
    autoload :Acquisition, "#{__dir__}/empeira/agent/acquisition"
    autoload :Artifact, "#{__dir__}/empeira/agent/artifact"
    autoload :Authentication, "#{__dir__}/empeira/agent/authentication"
    autoload :AuthenticationRequired, "#{__dir__}/empeira/agent/authentication"
    autoload :Cache, "#{__dir__}/empeira/agent/cache"
    autoload :CacheCorruption, "#{__dir__}/empeira/agent/cache"
    autoload :CacheStorage, "#{__dir__}/empeira/agent/cache_storage"
    autoload :Download, "#{__dir__}/empeira/agent/download"
    autoload :NativeCommands, "#{__dir__}/empeira/agent/native_commands"
    autoload :ReleaseSources, "#{__dir__}/empeira/agent/release_sources"
    autoload :Target, "#{__dir__}/empeira/agent/target"
    autoload :Versions, "#{__dir__}/empeira/agent/versions"
  end

  module Configuration
    autoload :AdditionalServices, "#{__dir__}/empeira/configuration/additional_services"
    autoload :Addons, "#{__dir__}/empeira/configuration/addons"
    autoload :AgentSchema, "#{__dir__}/empeira/configuration/agent_schema"
    autoload :AgentValues, "#{__dir__}/empeira/configuration/agent_values"
    autoload :BootstrapGuests, "#{__dir__}/empeira/configuration/bootstrap_guests"
    autoload :CommandMocks, "#{__dir__}/empeira/configuration/command_mocks"
    autoload :DNSRewrites, "#{__dir__}/empeira/configuration/dns_rewrites"
    autoload :Display, "#{__dir__}/empeira/configuration/display"
    autoload :Document, "#{__dir__}/empeira/configuration/document"
    autoload :Eyaml, "#{__dir__}/empeira/configuration/eyaml"
    autoload :HieraModulepath, "#{__dir__}/empeira/configuration/hiera_modulepath"
    autoload :HieraMountSchema, "#{__dir__}/empeira/configuration/hiera_mount_schema"
    autoload :HieraMounts, "#{__dir__}/empeira/configuration/hiera_mounts"
    autoload :ImageSchema, "#{__dir__}/empeira/configuration/image_schema"
    autoload :Loader, "#{__dir__}/empeira/configuration/loader"
    autoload :Merge, "#{__dir__}/empeira/configuration/merge"
    autoload :NetworkRedirects, "#{__dir__}/empeira/configuration/network_redirects"
    autoload :NodeImages, "#{__dir__}/empeira/configuration/node_images"
    autoload :SSHPreferences, "#{__dir__}/empeira/configuration/ssh_preferences"
    autoload :Schema, "#{__dir__}/empeira/configuration/schema"
    autoload :ServerMounts, "#{__dir__}/empeira/configuration/server_mounts"
    autoload :ServiceConfiguration, "#{__dir__}/empeira/configuration/service_configuration"
    autoload :User, "#{__dir__}/empeira/configuration/user"
    autoload :VMInterfaces, "#{__dir__}/empeira/configuration/vm_interfaces"
  end

  module ControlPlane
    autoload :AdditionalConfigurations, "#{__dir__}/empeira/control_plane/additional_configurations"
    autoload :Browser, "#{__dir__}/empeira/control_plane/browser"
    autoload :Controller, "#{__dir__}/empeira/control_plane/controller"
    autoload :DNSConfiguration, "#{__dir__}/empeira/control_plane/dns_configuration"
    autoload :Discovery, "#{__dir__}/empeira/control_plane/discovery"
    autoload :Environment, "#{__dir__}/empeira/control_plane/environment"
    autoload :Files, "#{__dir__}/empeira/control_plane/files"
    autoload :Health, "#{__dir__}/empeira/control_plane/health"
    autoload :Plan, "#{__dir__}/empeira/control_plane/plan"
    autoload :StartupFailure, "#{__dir__}/empeira/control_plane/startup_failure"
    autoload :Storage, "#{__dir__}/empeira/control_plane/storage"
  end

  module Execution
    autoload :Console, "#{__dir__}/empeira/execution/console"
    autoload :Diagnostics, "#{__dir__}/empeira/execution/diagnostics"
    autoload :LaunchError, "#{__dir__}/empeira/execution/launch_error"
    autoload :Result, "#{__dir__}/empeira/execution/result"
    autoload :Runner, "#{__dir__}/empeira/execution/runner"
    autoload :Terminal, "#{__dir__}/empeira/execution/terminal"
  end

  module Images
    autoload :Configuration, "#{__dir__}/empeira/images/configuration"
    autoload :Identity, "#{__dir__}/empeira/images/identity"
    autoload :Recipe, "#{__dir__}/empeira/images/recipe"
    autoload :Reference, "#{__dir__}/empeira/images/reference"
    autoload :Source, "#{__dir__}/empeira/images/source"
  end

  module Infrastructure
    autoload :Cancelled, "#{__dir__}/empeira/infrastructure/operation"
    autoload :Cleanup, "#{__dir__}/empeira/infrastructure/cleanup"
    autoload :Definition, "#{__dir__}/empeira/infrastructure/definition"
    autoload :Locked, "#{__dir__}/empeira/infrastructure/store"
    autoload :OwnedFiles, "#{__dir__}/empeira/infrastructure/owned_files"
    autoload :Operation, "#{__dir__}/empeira/infrastructure/operation"
    autoload :RecoveryInventory, "#{__dir__}/empeira/infrastructure/recovery_inventory"
    autoload :ResourceLock, "#{__dir__}/empeira/infrastructure/resource_lock"
    autoload :Service, "#{__dir__}/empeira/infrastructure/service"
    autoload :StateError, "#{__dir__}/empeira/infrastructure/store"
    autoload :Status, "#{__dir__}/empeira/infrastructure/status"
    autoload :Store, "#{__dir__}/empeira/infrastructure/store"
  end

  module Modules
    autoload :Events, "#{__dir__}/empeira/modules/events"
    autoload :GitSafety, "#{__dir__}/empeira/modules/git_safety"
    autoload :HostGit, "#{__dir__}/empeira/modules/host_git"
    autoload :Image, "#{__dir__}/empeira/modules/image"
    autoload :Installer, "#{__dir__}/empeira/modules/installer"
    autoload :Request, "#{__dir__}/empeira/modules/request"
    autoload :State, "#{__dir__}/empeira/modules/state"
    autoload :Storage, "#{__dir__}/empeira/modules/storage"
  end

  module Network
    autoload :Binding, "#{__dir__}/empeira/network/resource"
    autoload :BootstrapProxy, "#{__dir__}/empeira/network/bootstrap_proxy"
    autoload :Definition, "#{__dir__}/empeira/network/definition"
    autoload :DirectEgress, "#{__dir__}/empeira/network/direct_egress"
    autoload :Egress, "#{__dir__}/empeira/network/egress"
    autoload :Gateway, "#{__dir__}/empeira/network/gateway"
    autoload :HostPolicy, "#{__dir__}/empeira/network/host_policy"
    autoload :Interface, "#{__dir__}/empeira/network/policy"
    autoload :Naming, "#{__dir__}/empeira/network/naming"
    autoload :Policy, "#{__dir__}/empeira/network/policy"
    autoload :ProxyBindings, "#{__dir__}/empeira/network/proxy_bindings"
    autoload :ProxyPolicy, "#{__dir__}/empeira/network/proxy_policy"
    autoload :Redirects, "#{__dir__}/empeira/network/redirects"
    autoload :Resource, "#{__dir__}/empeira/network/resource"
    autoload :ResourceIdentity, "#{__dir__}/empeira/network/resource"
    autoload :UnsupportedPolicy, "#{__dir__}/empeira/network/policy"

    module Peer
      autoload :AdapterImage, "#{__dir__}/empeira/network/peer/adapter_image"
      autoload :Allocation, "#{__dir__}/empeira/network/peer/allocation"
      autoload :Attachment, "#{__dir__}/empeira/network/peer/attachment"
      autoload :Backend, "#{__dir__}/empeira/network/peer/backend"
      autoload :Channel, "#{__dir__}/empeira/network/peer/channel"
      autoload :ChannelServer, "#{__dir__}/empeira/network/peer/channel_server"
      autoload :DockerAdapter, "#{__dir__}/empeira/network/peer/docker_adapter"
      autoload :HelperSecurity, "#{__dir__}/empeira/network/peer/helper_security"
      autoload :Layout, "#{__dir__}/empeira/network/peer/layout"
      autoload :LinuxPodman, "#{__dir__}/empeira/network/peer/linux_podman"
      autoload :PodmanMachine, "#{__dir__}/empeira/network/peer/podman_machine"
    end
  end

  module Node
    autoload :Transaction, "#{__dir__}/empeira/node/transaction"
    autoload :AgentConfiguration, "#{__dir__}/empeira/node/agent_configuration"
    autoload :AgentInstallation, "#{__dir__}/empeira/node/agent_installer"
    autoload :AgentInstaller, "#{__dir__}/empeira/node/agent_installer"
    autoload :AgentPackage, "#{__dir__}/empeira/node/agent_package"
    autoload :AgentRepository, "#{__dir__}/empeira/node/agent_repository"
    autoload :AptConfiguration, "#{__dir__}/empeira/node/apt_configuration"
    autoload :Bootstrap, "#{__dir__}/empeira/node/bootstrap"
    autoload :Certificates, "#{__dir__}/empeira/node/certificates"
    autoload :CommandMock, "#{__dir__}/empeira/node/command_mock"
    autoload :CommandMocks, "#{__dir__}/empeira/node/command_mocks"
    autoload :Container, "#{__dir__}/empeira/node/container"
    autoload :ContainerAgentBootstrap, "#{__dir__}/empeira/node/container_agent_bootstrap"
    autoload :ContainerBootstrap, "#{__dir__}/empeira/node/container_bootstrap"
    autoload :ContainerGuest, "#{__dir__}/empeira/node/container_guest"
    autoload :ContainerLifecycle, "#{__dir__}/empeira/node/container_lifecycle"
    autoload :ContainerPreparation, "#{__dir__}/empeira/node/container_preparation"
    autoload :ContainerState, "#{__dir__}/empeira/node/container_state"
    autoload :Definition, "#{__dir__}/empeira/node/definition"
    autoload :DiagnosticCommand, "#{__dir__}/empeira/node/diagnostic_command"
    autoload :DnfAgentRepository, "#{__dir__}/empeira/node/dnf_agent_repository"
    autoload :ExternalFact, "#{__dir__}/empeira/node/external_fact"
    autoload :Image, "#{__dir__}/empeira/node/image"
    autoload :InitialPuppetRuns, "#{__dir__}/empeira/node/initial_puppet_runs"
    autoload :InteractiveTools, "#{__dir__}/empeira/node/interactive_tools"
    autoload :Interface, "#{__dir__}/empeira/node/interface"
    autoload :Inventory, "#{__dir__}/empeira/node/inventory"
    autoload :PackageBootstrap, "#{__dir__}/empeira/node/package_bootstrap"
    autoload :PackageProxy, "#{__dir__}/empeira/node/package_proxy"
    autoload :PackageSources, "#{__dir__}/empeira/node/package_sources"
    autoload :PuppetCommand, "#{__dir__}/empeira/node/puppet_command"
    autoload :RpmConfiguration, "#{__dir__}/empeira/node/rpm_configuration"
    autoload :RunRequest, "#{__dir__}/empeira/node/run_request"
    autoload :RuntimeProxy, "#{__dir__}/empeira/node/runtime_proxy"
    autoload :SSHClient, "#{__dir__}/empeira/node/ssh_client"
    autoload :SSHCredentials, "#{__dir__}/empeira/node/ssh_credentials"
    autoload :SSHEndpoint, "#{__dir__}/empeira/node/ssh_endpoint"
    autoload :SSHIdentity, "#{__dir__}/empeira/node/ssh_identity"
    autoload :Service, "#{__dir__}/empeira/node/service"
    autoload :UserSSH, "#{__dir__}/empeira/node/user_ssh"
    autoload :VM, "#{__dir__}/empeira/node/vm"
    autoload :VMBootstrap, "#{__dir__}/empeira/node/vm_bootstrap"
    autoload :VMLifecycle, "#{__dir__}/empeira/node/vm_lifecycle"
    autoload :VMPreflight, "#{__dir__}/empeira/node/vm_preflight"
    autoload :VMPreparation, "#{__dir__}/empeira/node/vm_preparation"
    autoload :VMState, "#{__dir__}/empeira/node/vm_state"
  end

  module Platform
    autoload :Facts, "#{__dir__}/empeira/platform/facts"
    autoload :Kvm, "#{__dir__}/empeira/platform/kvm"
    autoload :Locations, "#{__dir__}/empeira/platform/locations"
    autoload :Resolvers, "#{__dir__}/empeira/platform/resolvers"
    autoload :Routes, "#{__dir__}/empeira/platform/routes"
  end

  module Providers
    autoload :AlreadyExists, "#{__dir__}/empeira/providers/resource"
    autoload :ExecutionError, "#{__dir__}/empeira/providers/resource"
    autoload :Lifecycle, "#{__dir__}/empeira/providers/lifecycle"
    autoload :NotFound, "#{__dir__}/empeira/providers/resource"
    autoload :OwnershipError, "#{__dir__}/empeira/providers/resource"
    autoload :Registry, "#{__dir__}/empeira/providers/registry"
    autoload :Resource, "#{__dir__}/empeira/providers/resource"
    autoload :Result, "#{__dir__}/empeira/providers/resource"
  end

  module Runtime
    autoload :AgentHelper, "#{__dir__}/empeira/runtime/agent_helper"
    autoload :Container, "#{__dir__}/empeira/runtime/container"
    autoload :DiagnosticExecution, "#{__dir__}/empeira/runtime/diagnostic_execution"
    autoload :Docker, "#{__dir__}/empeira/runtime/docker"
    autoload :ImageMetadata, "#{__dir__}/empeira/runtime/image_metadata"
    autoload :Interface, "#{__dir__}/empeira/runtime/interface"
    autoload :MountProbe, "#{__dir__}/empeira/runtime/mount_probe"
    autoload :Podman, "#{__dir__}/empeira/runtime/podman"
    autoload :RecipeBuild, "#{__dir__}/empeira/runtime/recipe_build"
    autoload :RegistryDiagnostics, "#{__dir__}/empeira/runtime/registry_diagnostics"
    autoload :ServiceArguments, "#{__dir__}/empeira/runtime/service_arguments"
    autoload :ServiceImages, "#{__dir__}/empeira/runtime/service_images"
    autoload :ServiceInspection, "#{__dir__}/empeira/runtime/service_inspection"
    autoload :Services, "#{__dir__}/empeira/runtime/services"
    autoload :Unavailable, "#{__dir__}/empeira/runtime/container"
    autoload :UnsupportedCapability, "#{__dir__}/empeira/runtime/container"
    autoload :UpdateHelper, "#{__dir__}/empeira/runtime/update_helper"
    autoload :WorkspaceNetwork, "#{__dir__}/empeira/runtime/workspace_network"
  end

  module Server
    autoload :EnvironmentConfiguration, "#{__dir__}/empeira/server/environment_configuration"
    autoload :HTTP, "#{__dir__}/empeira/server/http"
    autoload :PuppetDBRuntime, "#{__dir__}/empeira/server/puppetdb_runtime"
    autoload :RelayCertificate, "#{__dir__}/empeira/server/relay_certificate"
    autoload :Runtime, "#{__dir__}/empeira/server/runtime"
  end

  module Services
    autoload :Definition, "#{__dir__}/empeira/services/definition"
  end

  module Updates
    autoload :CommandFailed, "#{__dir__}/empeira/updates/service"
    autoload :Images, "#{__dir__}/empeira/updates/images"
    autoload :Modules, "#{__dir__}/empeira/updates/modules"
    autoload :Service, "#{__dir__}/empeira/updates/service"
  end

  module VM
    autoload :Agent, "#{__dir__}/empeira/vm/agent"
    autoload :BootstrapRequirements, "#{__dir__}/empeira/vm/bootstrap_requirements"
    autoload :CertificateRuntime, "#{__dir__}/empeira/vm/certificate_runtime"
    autoload :CloudInit, "#{__dir__}/empeira/vm/cloud_init"
    autoload :Disk, "#{__dir__}/empeira/vm/disk"
    autoload :Guest, "#{__dir__}/empeira/vm/guest"
    autoload :GuestChannel, "#{__dir__}/empeira/vm/guest_channel"
    autoload :GuestNetwork, "#{__dir__}/empeira/vm/guest_network"
    autoload :GuestOutput, "#{__dir__}/empeira/vm/guest_output"
    autoload :GuestShell, "#{__dir__}/empeira/vm/guest_shell"
    autoload :GuestUpload, "#{__dir__}/empeira/vm/guest_upload"
    autoload :ImageCache, "#{__dir__}/empeira/vm/image_cache"
    autoload :ImageSource, "#{__dir__}/empeira/vm/image_source"
    autoload :Interface, "#{__dir__}/empeira/vm/interface"
    autoload :InterfaceOwnership, "#{__dir__}/empeira/vm/interface_ownership"
    autoload :InterfaceRoutes, "#{__dir__}/empeira/vm/interface_routes"
    autoload :Interfaces, "#{__dir__}/empeira/vm/interfaces"
    autoload :Management, "#{__dir__}/empeira/vm/management"
    autoload :Prerequisites, "#{__dir__}/empeira/vm/prerequisites"
    autoload :Qemu, "#{__dir__}/empeira/vm/qemu"
    autoload :QemuRuntime, "#{__dir__}/empeira/vm/qemu_runtime"
    autoload :Removal, "#{__dir__}/empeira/vm/removal"
    autoload :RootDisk, "#{__dir__}/empeira/vm/root_disk"
    autoload :SystemSSH, "#{__dir__}/empeira/vm/system_ssh"
  end
end

require_relative 'empeira/providers'
