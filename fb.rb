require 'koala'
require 'yaml'
require 'date'
require 'slack-ruby-client'

raise unless ARGV.count == 1
config = YAML.load_file ARGV.first
SLACK = Slack::Web::Client.new(token: config['slack_token'])

begin
LAST_CHECK = config['last_check']
raise 'no last check date in config' if LAST_CHECK.nil?
Koala.config.api_version = 'v2.9'
graph = Koala::Facebook::API.new config['access_token']
CHANNEL = config['channel']
GROUP_ID = config['group_id']

def post_to_slack post
  message = post[:quote].nil?? "*%s*\nPermalink: %s" : "*%s*\n>>>%s\nPermalink: %s"
  message << "\nAttachment: %s" unless post[:attachment].nil?
  SLACK.chat_postMessage(channel: CHANNEL, text: (message % post.values).gsub(/[&<>]/, {'&' => '&amp;', '<' => '&lt;', '>' => '&gt;'}), as_user: true)
end

def get_attachment post
  case post['type']
  when 'link'
    post['link']
  when 'photo'
    graph.get_picture_data(post['object_id'])['data']['url']
  else
    nil
  end
end

feed = graph.get_object(GROUP_ID + '/feed', {since: LAST_CHECK.to_s,
                                         fields: 'message,object_id,updated_time,created_time,type,story,from,permalink_url,comments{created_time,message,from,permalink_url,comments},link'})
files = graph.get_object(GROUP_ID + '/files', {fields: 'download_link,updated_time,from'})

config['last_check'] = feed.empty?? DateTime.now : DateTime.parse(feed.first['updated_time'])
File.write(ARGV.first, YAML.dump(config))

files.keep_if {|f| DateTime.parse(f['updated_time']) >= LAST_CHECK}
feed.each do |post|
  if DateTime.parse(post['created_time']) >= LAST_CHECK
    post_to_slack(header: post['story'] || post['from']['name'], quote: post['message'], permalink: post['permalink_url'], attachment: get_attachment(post))
  end

  unless post['comments'].nil?
    post['comments']['data'].each do |comment|
      if DateTime.parse(comment['created_time']) >= LAST_CHECK
        post_to_slack(header: "%s commented on %s's post." % [comment['from']['name'], post['from']['name']], quote: comment['message'], permalink: comment['permalink_url'])
      end

      unless comment['comments'].nil?
        comment['comments']['data'].each do |reply|
          if DateTime.parse(reply['created_time']) >= LAST_CHECK
            post_to_slack(header: "%s replied to %s's comment." % [reply['from']['name'], comment['from']['name']], quote: reply['message'], permalink: comment['permalink_url'])
          end
        end
      end
    end
  end
end

files.each do |f|
  post_to_slack(header: "A file was posted by #{f['from']['name']}.", permalink: f['download_link'])
end

rescue => e
  SLACK.chat_postMessage(channel: '@jerryskye', text: "```#{e.class}: #{e}\n#{e.backtrace.join("\n")}```", as_user: true)
end
