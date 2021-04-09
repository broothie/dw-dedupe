require 'httparty'
require 'json'
require_relative 'spotify_client'

class Spotify
  ALPHABET = ('a'..'z').to_a.freeze
  REDIRECT_PATH = '/spotify/authorize/redirect'.freeze
  CALLBACK_PATH = '/spotify/authorize/callback'.freeze
  SCOPES = 'playlist-read-private playlist-modify-private'.freeze

  def initialize(app_config)
    @client_id = app_config.spotify_client_id
    @development = app_config.development?
    @callback_uri = "#{app_config.base_url}#{CALLBACK_PATH}"
    @client = SpotifyClient.new(
      app_config.spotify_client_id,
      app_config.spotify_client_secret,
      callback_uri
    )
  end

  def dw_dedupe_playlist_name
    development? ? 'DW Dedupe - dev' : 'DW Dedupe'
  end

  def new_state(length = 32)
    Array.new(length) { ALPHABET.sample }.join
  end

  def redirect_uri(state)
    "#{SpotifyClient::ACCOUNTS_BASE_URL}/authorize?#{redirect_query(state)}"
  end

  def user_from_code(code)
    auth_response = client.access_token_from_code(code)
    user_info = client.get_user_info(auth_response['access_token'])

    user_info.merge('credentials' => auth_response)
  end

  def refresh_token!(user)
    response = client.access_token_from_refresh_token(user.dig('credentials', 'refresh_token'))
    user['credentials'].merge!(response)
  end

  def set_discover_weekly!(user)
    discover_weekly = find_discover_weekly(user)
    raise 'no discover weekly found' unless discover_weekly

    user['discover_weekly_id'] = discover_weekly['id']
  end

  def update_dw_dedupe!(user)
    suggested_track_ids = Set.new(user.fetch('track_ids', []))

    discover_weekly = client.get_playlist(token_for(user), user['discover_weekly_id'])
    discover_weekly_track_ids = discover_weekly.dig('tracks', 'items').map { |pl_track| pl_track.dig('track', 'id') }
    new_track_ids = discover_weekly_track_ids.reject { |track_id| suggested_track_ids.include?(track_id) }
    suggested_track_ids.merge(discover_weekly_track_ids)

    begin
      dw_dedupe = client.get_playlist(token_for(user), user['dw_dedupe_id'])
    rescue StandardError
      dw_dedupe = upsert_dw_dedupe(user)
      user['dw_dedupe_id'] = dw_dedupe['id']
    end

    dw_dedupe_track_ids = dw_dedupe.dig('tracks', 'items').map { |pl_track| pl_track.dig('track', 'id') }
    client.remove_tracks_from_playlist(token_for(user), user['dw_dedupe_id'], dw_dedupe_track_ids)
    client.add_tracks_to_playlist(token_for(user), user['dw_dedupe_id'], new_track_ids)

    user['track_ids'] = suggested_track_ids.to_a
  end

  private

  attr_reader :client_id
  attr_reader :development
  attr_reader :callback_uri
  attr_reader :client
  alias development? development

  def find_discover_weekly(user)
    offset = 0
    loop do
      response = client.get_user_playlists(token_for(user), offset: offset)
      playlists = response['items']
      return nil if playlists.empty?

      playlists.each do |playlist|
        return playlist.to_h if playlist['name'] == 'Discover Weekly' && playlist.dig('owner', 'id') == 'spotify'
      end

      offset += 50
    end
  end

  def find_dw_dedupe(user)
    offset = 0
    loop do
      response = client.get_user_playlists(token_for(user), offset: offset)
      playlists = response['items']
      return nil if playlists.empty?

      playlists.each do |playlist|
        return playlist.to_h if playlist['name'] == dw_dedupe_playlist_name && playlist.dig('owner', 'id') == user['id']
      end

      offset += 50
    end
  end

  def upsert_dw_dedupe(user)
    existing_dw_dedupe = find_dw_dedupe(user)
    return existing_dw_dedupe if existing_dw_dedupe

    client.create_playlist(token_for(user), user['id'], dw_dedupe_playlist_name)
  end

  def token_for(user)
    user.dig('credentials', 'access_token')
  end

  def redirect_query(state)
    URI.encode_www_form(
      response_type: :code,
      client_id: client_id,
      state: state,
      scope: SCOPES,
      redirect_uri: callback_uri
    )
  end
end
