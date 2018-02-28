require 'sinatra'
require 'koala'
require 'yaml'
require 'slack-ruby-client'

set :config, YAML.load_file('config.yml')
Koala.config.api_version = 'v2.12'
set :oauth, Koala::Facebook::OAuth.new(settings.config['fb_app_id'], settings.config['fb_app_secret'], settings.config['fb_redirect_url'])

get '/' do
  redirect settings.oauth.url_for_oauth_code(permissions: 'user_managed_groups')
end

get '/gettoken' do
  short_lived_token = settings.oauth.get_access_token(@params['code'])
  access_token_with_info = settings.oauth.exchange_access_token_info(short_lived_token)
  access_token = access_token_with_info['access_token']
  graph = Koala::Facebook::API.new access_token
  graph.get_object('/me/groups').each do |group|
    fname = group['id'] + '.yml'
    if File.exists? fname
      cnf = YAML.load_file fname
      cnf['access_token'] = access_token
      File.write fname, YAML.dump(cnf)
    end
  end

  Slack::Web::Client.new(token: settings.config['slack_token']).reminders_add(text: 'Token expires tomorrow, pls visit https://jarek.siedlarz.com/token', time: (Time.now + access_token_with_info['expires_in'] - 86400).to_i, user: settings.config['user_to_remind'])
  'Dziękuję.'
end
