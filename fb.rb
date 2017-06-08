require 'koala'
require 'yaml'
require 'pry'

config = YAML.load_file 'config.yml'

Koala.config.api_version = 'v2.9'
graph = Koala::Facebook::API.new config['access_token']
pry
