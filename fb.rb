require 'koala'
require 'yaml'
require 'date'

config = YAML.load_file 'config.yml'
LAST_CHECK = config['last_check']
raise 'no last check date in config.yml' if LAST_CHECK.nil?
Koala.config.api_version = 'v2.9'
graph = Koala::Facebook::API.new config['access_token']
config['last_check'] = DateTime.now
File.write 'config.yml', YAML.dump(config)

feed, files = graph.batch do |api|
  api.get_object '933955260017967/feed', {since: LAST_CHECK.to_s,
                                         fields: 'message,object_id,updated_time,created_time,type,story,from,permalink_url,comments{created_time,message,from,permalink_url},link'}
  api.get_object '933955260017967/files', {fields: 'download_link,updated_time,from'}
end

files.keep_if {|f| DateTime.parse(f['updated_time']) >= LAST_CHECK}
feed.each do |post|
  if DateTime.parse(post['created_time']) >= LAST_CHECK
    puts(post['story'] || post['from']['name'])
    puts post['message'] unless post['message'].nil?
    case post['type']
    when 'link'
      puts post['link']
    when 'photo'
      puts graph.get_picture_data(post['object_id'])['data']['url']
    end
    puts post['permalink_url'] + "\n\n"
  end

  unless post['comments'].nil?
    post['comments']['data'].each do |comment|
      puts "%s commented on %s's post" % [comment['from']['name'], post['from']['name']]
      puts comment['message'] unless comment['message'].nil?
      puts comment['permalink_url'] + "\n\n"
    end
  end
end

files.each do |f|
  puts "New file was posted by %s." % f['from']['name']
  puts f['download_link'] + "\n\n"
end
