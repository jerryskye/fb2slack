require 'koala'
require 'yaml'
require 'date'
require 'slack-ruby-client'

raise unless ARGV.count == 1
config = YAML.load_file ARGV.first
slack = Slack::Web::Client.new(token: config['slack_token'])
begin
LAST_CHECK = config['last_check']
raise 'no last check date in config.yml' if LAST_CHECK.nil?
Koala.config.api_version = 'v2.9'
graph = Koala::Facebook::API.new config['access_token']
CHANNEL = config['channel']
GROUP_ID = config['group_id']
config['last_check'] = DateTime.now
File.write(ARGV.first, YAML.dump(config))

feed, files = graph.batch do |api|
  api.get_object GROUP_ID + '/feed', {since: LAST_CHECK.to_s,
                                         fields: 'message,object_id,updated_time,created_time,type,story,from,permalink_url,comments{created_time,message,from,permalink_url},link'}
  api.get_object GROUP_ID + '/files', {fields: 'download_link,updated_time,from'}
end

files.keep_if {|f| DateTime.parse(f['updated_time']) >= LAST_CHECK}
feed.each do |post|
  if DateTime.parse(post['created_time']) >= LAST_CHECK
    slack.chat_postMessage(channel: CHANNEL, text: '*%s*' % (post['story'] || post['from']['name']), as_user: true)
    slack.chat_postMessage(channel: CHANNEL, text:  '>>>' + post['message'], as_user: true) unless post['message'].nil?
    case post['type']
    when 'link'
      slack.chat_postMessage(channel: CHANNEL, text: post['link'], as_user: true)
    when 'photo'
      slack.chat_postMessage(channel: CHANNEL, text: graph.get_picture_data(post['object_id'])['data']['url'], as_user: true)
    end
    slack.chat_postMessage(channel: CHANNEL, text: post['permalink_url'], as_user: true)
  end

  unless post['comments'].nil?
    post['comments']['data'].each do |comment|
      slack.chat_postMessage(channel: CHANNEL, text: "*%s commented on %s's post*" % [comment['from']['name'], post['from']['name']], as_user: true)
      slack.chat_postMessage(channel: CHANNEL, text: '>>>' + comment['message'], as_user: true) unless comment['message'].nil?
      slack.chat_postMessage(channel: CHANNEL, text: comment['permalink_url'], as_user: true)
    end
  end
end

files.each do |f|
  slack.chat_postMessage(channel: CHANNEL, text: "*New file was posted by %s*" % f['from']['name'], as_user: true)
  slack.chat_postMessage(channel: CHANNEL, text: f['download_link'], as_user: true)
end

rescue => e
  slack.chat_postMessage(channel: '@jerryskye', text: "```#{e.class}: #{e}\n#{e.backtrace.join("\n")}```", as_user: true)
end
