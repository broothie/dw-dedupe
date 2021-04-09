require 'httparty'
require 'json'

class Spotify
  ALPHABET = ('a'..'z').to_a.freeze
  REDIRECT_PATH = '/spotify/authorize/redirect'.freeze
  CALLBACK_PATH = '/spotify/authorize/callback'.freeze
  CLIENT_ID = ENV.fetch('SPOTIFY_CLIENT_ID').freeze
  CLIENT_SECRET = ENV.fetch('SPOTIFY_CLIENT_SECRET').freeze
  HOSTNAME = ENV.fetch('HOSTNAME', 'localhost').freeze
  SCOPES = 'playlist-read-private playlist-modify-private'.freeze

  attr_reader :development
  attr_reader :port
  alias development? development

  def initialize(sinatra_settings)
    @development = sinatra_settings.development?
    @port = sinatra_settings.port
  end

  def dw_dedupe_playlist_name
    development? ? 'DW Dedupe - dev' : 'DW Dedupe'
  end

  def new_state(length = 32)
    Array.new(length) { ALPHABET.sample }.join
  end

  def redirect_uri(state)
    "https://accounts.spotify.com/authorize?#{redirect_query(state)}"
  end

  def user_from_code(code)
    auth_response = fetch_tokens(code)
    user_info = fetch_user_info(auth_response['access_token'])

    user_info.to_h.merge('credentials' => auth_response.to_h)
  end

  def refresh_token!(user)
    response = fetch_refreshed_access_token(user.dig('credentials', 'refresh_token'))
    user['credentials'].merge!(response.to_h)
  end

  def set_discover_weekly!(user)
    discover_weekly = find_discover_weekly(user)
    raise 'no discover weekly found' unless discover_weekly

    user['discover_weekly_id'] = discover_weekly['id']
  end

  def update_dw_dedupe!(user)
    suggested_track_ids = Set.new(user.fetch('track_ids', []))

    discover_weekly = fetch_playlist(token_for(user), user['discover_weekly_id'])
    discover_weekly_track_ids = discover_weekly.dig('tracks', 'items').map { |pl_track| pl_track.dig('track', 'id') }
    new_track_ids = discover_weekly_track_ids.reject { |track_id| suggested_track_ids.include?(track_id) }
    suggested_track_ids.merge(discover_weekly_track_ids)

    dw_dedupe = fetch_playlist(token_for(user), user['dw_dedupe_id'])
    unless dw_dedupe
      dw_dedupe = upsert_dw_dedupe(user)
      user['dw_dedupe_id'] = dw_dedupe['id']
    end

    dw_dedupe_track_ids = dw_dedupe.dig('tracks', 'items').map { |pl_track| pl_track.dig('track', 'id') }
    remove_tracks_from_playlist(token_for(user), user['dw_dedupe_id'], dw_dedupe_track_ids)
    add_tracks_to_playlist(token_for(user), user['dw_dedupe_id'], new_track_ids)

    user['track_ids'] = suggested_track_ids.to_a
  end

  private

  def find_discover_weekly(user)
    offset = 0
    loop do
      response = fetch_user_playlists(token_for(user), limit: 50, offset: offset)
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
      response = fetch_user_playlists(token_for(user), limit: 50, offset: offset)
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

    create_playlist(token_for(user), user['id'], dw_dedupe_playlist_name)
  end

  def token_for(user)
    user.dig('credentials', 'access_token')
  end

  def fetch_tokens(code)
    HTTParty.post(
      'https://accounts.spotify.com/api/token',
      headers: basic_auth_headers,
      body: URI.encode_www_form(grant_type: :authorization_code, code: code, redirect_uri: callback_uri)
    )
  end

  def fetch_refreshed_access_token(refresh_token)
    HTTParty.post(
      'https://accounts.spotify.com/api/token',
      headers: basic_auth_headers,
      body: URI.encode_www_form(grant_type: :refresh_token, refresh_token: refresh_token)
    )
  end

  def fetch_user_info(access_token)
    HTTParty.get('https://api.spotify.com/v1/me', headers: bearer_auth_headers(access_token))
  end

  def fetch_user_playlists(access_token, limit: 50, offset: 0)
    HTTParty.get(
      'https://api.spotify.com/v1/me/playlists',
      headers: bearer_auth_headers(access_token),
      query: { limit: limit, offset: offset }
    )
  end

  def create_playlist(access_token, user_id, playlist_name)
    HTTParty.post(
      "https://api.spotify.com/v1/users/#{user_id}/playlists",
      headers: bearer_auth_headers(access_token),
      body: { name: playlist_name, public: false }.to_json
    )
  end

  def fetch_playlist(access_token, playlist_id)
    HTTParty.get(
      "https://api.spotify.com/v1/playlists/#{playlist_id}",
      headers: bearer_auth_headers(access_token),
    )
  end

  def remove_tracks_from_playlist(access_token, playlist_id, track_ids)
    HTTParty.delete(
      "https://api.spotify.com/v1/playlists/#{playlist_id}/tracks",
      headers: bearer_auth_headers(access_token),
      body: { tracks: track_ids.map { |track_id| { uri: "spotify:track:#{track_id}" } } }.to_json
    )
  end

  def add_tracks_to_playlist(access_token, playlist_id, track_ids)
    HTTParty.post(
      "https://api.spotify.com/v1/playlists/#{playlist_id}/tracks",
      headers: bearer_auth_headers(access_token),
      body: { uris: track_ids.map { |track_id| "spotify:track:#{track_id}" } }.to_json
    )
  end

  def bearer_auth_headers(access_token)
    { Authorization: "Bearer #{access_token}" }
  end

  def basic_auth_headers
    @basic_auth_headers ||= { Authorization: "Basic #{encoded_api_keys}" }
  end

  def encoded_api_keys
    @encoded_api_keys ||= Base64.urlsafe_encode64("#{CLIENT_ID}:#{CLIENT_SECRET}")
  end

  def redirect_query(state)
    URI.encode_www_form(
      response_type: :code,
      client_id: CLIENT_ID,
      state: state,
      scope: SCOPES,
      redirect_uri: callback_uri
    )
  end

  def callback_uri
    @spotify_callback_uri ||= "#{base_url}#{CALLBACK_PATH}"
  end

  def base_url
    @base_url ||= development? ? "http://#{HOSTNAME}:#{port}" : "https://#{HOSTNAME}"
  end
end
