require 'dotenv/load'
require 'sinatra'
require 'google/cloud/firestore'
require 'active_support'
require 'active_support/core_ext/hash'
require 'json'
require_relative 'app_config'
require_relative 'spotify'

if development?
  require 'sinatra/reloader'
  also_reload "#{__dir__}/**/*.rb"
end

set session_secret: ENV.fetch('SESSION_SECRET')
enable :sessions

error do
  @message = env['sinatra.error'].message
  erb :error
end

get '/ping' do
  'pong'
end

get '/style.css' do
  scss :style
end

get '/' do
  require_user!
  erb :home
end

get '/history' do
  require_user!

  @history = spotify.client.get_tracks_info(spotify.token_for(@user), @user['track_ids']).fetch('tracks')
  erb :history
end

get '/latest' do
  require_user!

  @latest = spotify.client.get_tracks_info(spotify.token_for(@user), @user['latest_repeat_ids']).fetch('tracks')
  erb :latest
end

get '/login' do
  redirect '/' if session.key?(:spotify_user_id)
  @redirect_path = Spotify::REDIRECT_PATH
  erb :login
end

get '/logout' do
  session.delete(:spotify_user_id)
  redirect '/login'
end

get '/jobs/update' do
  # Update each user's DW Dedupe
  users.get.each do |user_doc|
    next unless user_doc.exists?

    user = user_doc.data&.deep_stringify_keys

    spotify.refresh_token!(user)
    spotify.update_dw_dedupe!(user)

    users.doc(user['id']).set(user, merge: true)
  end

  status :ok
end

get Spotify::REDIRECT_PATH do
  state = spotify.new_state
  session[:state] = state
  redirect spotify.redirect_uri(state)
end

get Spotify::CALLBACK_PATH do
  require_state_match!
  require_no_spotify_error!

  # Get user and set session
  user = spotify.user_from_code(params[:code])
  session[:spotify_user_id] = user['id']

  # Create user in db if not present
  unless users.doc(user['id']).get.exists?
    spotify.set_discover_weekly!(user)
    spotify.update_dw_dedupe!(user)
    users.doc(user['id']).set(user)
  end

  redirect '/'
end

helpers do
  def config
    @config ||= AppConfig.new(environment: settings.environment, port: settings.port)
  end

  def spotify
    @spotify ||= Spotify.new(config)
  end

  def firestore
    @firestore ||= Google::Cloud::Firestore.new
  end

  def users
    @users ||= firestore.collection("#{collection_prefix}.users")
  end

  def collection_prefix
    @collection_prefix ||= settings.development? ? "development.#{`whoami`.chomp}" : 'production'
  end

  def log(level, message, **kwargs)
    logger.send(level, { message: message }.merge(kwargs).to_json)
  end

  %i[error info debug].each do |level|
    define_method("log_#{level}") { |message, **kwargs| log level, message, **kwargs }
  end

  def require_user!
    redirect '/login' unless session.key?(:spotify_user_id)

    user = users.doc(session[:spotify_user_id]).get
    unless user.exists?
      session.delete(:spotify_user_id)
      redirect '/login'
    end

    @user = user.data&.deep_stringify_keys
    spotify.refresh_token!(@user)
  end

  def require_state_match!
    callback_state = params[:state]
    session_state = session.delete(:state)
    return if callback_state == session_state

    log_error "states don't match", { callback_state: callback_state, session_state: session_state }
    @message = "States don't match"
    erb :error
  end

  def require_no_spotify_error!
    return unless params.key?(:error)

    log_error "Spotify authorization error", error: params[:error]
    @message = "Spotify authorization error"
    erb :error
  end
end
