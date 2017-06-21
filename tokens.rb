require 'sinatra'
require 'koala'
require 'pry'
require 'yaml'

set :config, YAML.load_file('config.yml')
Koala.config.api_version = 'v2.9'
set :oauth, Koala::Facebook::OAuth.new(settings.config['app_id'], settings.config['app_secret'], settings.config['redirect_url'])

get '/' do
  redirect settings.oauth.url_for_oauth_code(permissions: 'user_managed_groups')
end

get '/gettoken' do
  short_lived_token = settings.oauth.get_access_token(@params['code'])
  access_token = settings.oauth.exchange_access_token(short_lived_token)
  graph = Koala::Facebook::API.new access_token
  graph.get_object('/me/groups').each do |group|
    fname = group['id'] + '.yml'
    if File.exists? fname
      cnf = YAML.load_file fname
      cnf['access_token'] = access_token
      File.write fname, YAML.dump(cnf)
    end
  end

  'Dziękuję.'
end
