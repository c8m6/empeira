# frozen_string_literal: true

module LivePersonalSSH
  # rubocop:disable-next Metrics/AbcSize -- Reuse one fixture identity through absolute and home-relative preferences.
  def personal_ssh_application(app, locations:, login:, pattern:)
    directory = locations.home.join('.ssh')
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.link(login.identity, directory.join('lab-key'))
    preferences = { 'user' => 'unconfigured-login', 'identity' => login.identity.to_s,
                    'rules' => [{ 'hosts' => [pattern.upcase], 'user' => login.username },
                                { 'hosts' => ['*'], 'identity' => '~/.ssh/lab-key' }] }
    locations.user_configuration.write(YAML.dump('ssh' => preferences))
    Empeira::Application.new(project_path: app.context.project.path, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => app.context.container_engine } })
  end

  def verify_personal_ssh_sessions(app, name:, login:)
    verify_ssh_session(app, name: name, user: login.username)
    verify_ssh_session(app, name: name, user: login.username, override_user: login.username)
    verify_ssh_session(app, name: name, user: login.username, identity: login.identity)
  end
end
