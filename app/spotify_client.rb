require 'httparty'
require 'json'

class SpotifyClient
  ACCOUNTS_BASE_URL = 'https://accounts.spotify.com'.freeze
  API_BASE_URL = 'https://api.spotify.com'.freeze

  def initialize(client_id, client_secret, redirect_uri)
    @client_id = client_id
    @client_secret = client_secret
    @redirect_uri = redirect_uri
  end

  def access_token_from_code(code)
    post(
      "#{ACCOUNTS_BASE_URL}/api/token",
      headers: basic_auth_headers,
      body: URI.encode_www_form(grant_type: :authorization_code, code: code, redirect_uri: redirect_uri)
    )
  end

  def access_token_from_refresh_token(refresh_token)
    post(
      "#{ACCOUNTS_BASE_URL}/api/token",
      headers: basic_auth_headers,
      body: URI.encode_www_form(grant_type: :refresh_token, refresh_token: refresh_token)
    )
  end

  def get_user_info(access_token)
    get("#{API_BASE_URL}/v1/me", headers: bearer_auth_headers(access_token))
  end

  def get_user_playlists(access_token, limit: 50, offset: 0)
    get(
      "#{API_BASE_URL}/v1/me/playlists",
      headers: bearer_auth_headers(access_token),
      query: { limit: limit, offset: offset }
    )
  end

  def create_playlist(access_token, user_id, playlist_name)
    post(
      "#{API_BASE_URL}/v1/users/#{user_id}/playlists",
      headers: bearer_auth_headers(access_token),
      body: { name: playlist_name, public: false }.to_json
    )
  end

  def get_playlist(access_token, playlist_id)
    get("#{API_BASE_URL}/v1/playlists/#{playlist_id}", headers: bearer_auth_headers(access_token))
  end

  def add_tracks_to_playlist(access_token, playlist_id, track_ids)
    post(
      "#{API_BASE_URL}/v1/playlists/#{playlist_id}/tracks",
      headers: bearer_auth_headers(access_token),
      body: { uris: track_ids.map { |track_id| "spotify:track:#{track_id}" } }.to_json
    )
  end

  def remove_tracks_from_playlist(access_token, playlist_id, track_ids)
    delete(
      "#{API_BASE_URL}/v1/playlists/#{playlist_id}/tracks",
      headers: bearer_auth_headers(access_token),
      body: { tracks: track_ids.map { |track_id| { uri: "spotify:track:#{track_id}" } } }.to_json
    )
  end

  private

  attr_reader :client_id
  attr_reader :client_secret
  attr_reader :redirect_uri

  %i[get post delete].each do |method|
    define_method(method) { |*args, **kwargs| check_response!(HTTParty.send(method, *args, **kwargs)) }
  end

  def basic_auth_headers
    @basic_auth_headers ||= { Authorization: "Basic #{encoded_api_keys}" }
  end

  def encoded_api_keys
    @encoded_api_keys ||= Base64.urlsafe_encode64("#{client_id}:#{client_secret}")
  end

  def check_response!(response)
    raise "http error: #{response}" unless response_ok?(response)

    response.to_h
  end

  def response_ok?(response)
    response.code.to_s.start_with?('2')
  end

  def bearer_auth_headers(access_token)
    { Authorization: "Bearer #{access_token}" }
  end
end
