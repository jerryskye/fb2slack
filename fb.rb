require 'koala'
require 'yaml'
require 'date'
require 'slack-ruby-client'

raise 'Usage: ruby fb.rb config_file log_file' unless ARGV.count == 2
config = YAML.load_file ARGV.first
SLACK = Slack::Web::Client.new(token: config['slack_token'])

begin
LAST_CHECK = config['last_check']
raise 'no last check date in config' if LAST_CHECK.nil?
Koala.config.api_version = 'v2.10'
LOGGER = Logger.new ARGV[1], 'daily'
Koala::Utils.logger = LOGGER
GRAPH = Koala::Facebook::API.new config['access_token']
CHANNEL = config['channel']
GROUP_ID = config['group_id']

def post_to_slack post
  message = post[:quote].nil?? "*%s*\nPermalink: %s" : "*%s*\n>>>%s\nPermalink: %s"
  message << "\nAttachments: %s" unless post[:attachments].nil? or post[:attachments].empty?
  SLACK.chat_postMessage(channel: CHANNEL, text: (message % post.compact.values).gsub(/[&<>]/, {'&' => '&amp;', '<' => '&lt;', '>' => '&gt;'}), as_user: true, unfurl_links: false)
end

def get_attachments post
  unless post['attachments'].nil?
    post['attachments']['data'].map do |attachment|
      case attachment['type']
      when 'photo'
        attachment['media']['image']['src']
      when 'album'
        (attachment['subattachments']['data'].map {|sub| sub['media']['image']['src']}.join("\n"))
      when 'file_upload'
        attachment['url']
      end
    end.join("\n")
  else
    case post['type']
    when 'photo'
      GRAPH.get_object(post['object_id'], fields: 'images')['images'].first['source']
    when 'link'
      post['link']
    end
  end
end

feed = GRAPH.get_object(GROUP_ID + '/feed', {since: LAST_CHECK.to_s,
  fields: 'message,object_id,updated_time,created_time,type,story,from,permalink_url,comments.filter(stream){created_time,message,from,permalink_url,attachment,parent},link'})
files = GRAPH.get_object(GROUP_ID + '/files', {since: LAST_CHECK.to_s, fields: 'download_link,updated_time,from'})

LOGGER.info 'feed.count: %d' % feed.count

unless feed.empty?
  config['last_check'] = DateTime.parse(feed.first['updated_time'])
  LOGGER.info "inserting #{config['last_check']} into last_check"
  File.write(ARGV.first, YAML.dump(config))
end

feed.each do |post|
  if DateTime.parse(post['created_time']) > LAST_CHECK
    post_to_slack(header: post['story'] || post['from']['name'], quote: post['message'], permalink: post['permalink_url'], attachments: get_attachments(post))
  end

  unless post['comments'].nil?
    post['comments']['data'].each do |comment|
      if DateTime.parse(comment['created_time']) > LAST_CHECK
        parent = comment['parent']
        if parent.nil?
          header = "%s commented on %s's post." % [comment['from']['name'], post['from']['name']]
        else
          header = "%s replied to %s's comment." % [comment['from']['name'], parent['from']['name']]
        end
        attachment = comment.dig('attachment', 'media', 'image', 'src') if comment.dig('attachment', 'type') == 'photo'
        post_to_slack(header: header, quote: comment['message'], permalink: comment['permalink_url'], attachments: attachment)
      end
    end
  end
end

files.each do |f|
  post_to_slack(header: "A file uploaded by #{f['from']['name']} can be downloaded here:", permalink: f['download_link'])
end

rescue => e
  SLACK.chat_postMessage(channel: '@jerryskye', text: "```#{e.class}: #{e}\n#{e.backtrace.join("\n")}```", as_user: true)
end
