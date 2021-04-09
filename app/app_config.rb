require_relative 'lib/config'

class AppConfig
  include Config

  config environment: 'development'
  config :port
  config hostname: 'localhost'
  config :session_secret
  config :spotify_client_id
  config :spotify_client_secret

  %i[development production].each { |env| define_method("#{env}?") { env == environment } }

  def base_url
    @base_url ||= development? ? "http://#{hostname}:#{port}" : "https://#{hostname}"
  end
end
