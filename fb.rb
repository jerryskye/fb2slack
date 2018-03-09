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
Koala.config.api_version = 'v2.12'
LOGGER = Logger.new ARGV[1], 'daily'
Koala::Utils.logger = LOGGER
GRAPH = Koala::Facebook::API.new config['fb_access_token']
CHANNEL = config['slack_channel']
GROUP_ID = config['fb_group_id']
USER_TO_NOTIFY = config['slack_user_to_notify']

def post_to_slack post
  message = post[:quote].nil?? "*%s*\nPermalink: %s" : "*%s*\n>>> %s\nPermalink: %s"
  message << "\nAttachments: %s" unless post[:attachments].nil? or post[:attachments].empty?
  SLACK.chat_postMessage(channel: CHANNEL, text: (message % post.compact.values).gsub(/[&<>]/, {'&' => '&amp;', '<' => '&lt;', '>' => '&gt;'}), as_user: true, unfurl_links: false)
end

def get_attachments post
  if not post['attachments'].nil?
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
  elsif post.has_key? 'attachment'
    case post.dig('attachment', 'type')
    when 'photo'
      post.dig('attachment', 'media', 'image', 'src')
    when 'animated_image_share'
      post.dig('attachment', 'url')
    end
  else
    case post['type']
    when 'photo'
      GRAPH.get_object(post['object_id'], fields: 'images')['images'].first['source']
    when 'link'
      post['link']
    end
  end
end

def handle_comment comment, post_author
  if DateTime.parse(comment['created_time']) > LAST_CHECK
    parent = comment['parent']
    if parent.nil?
      header = "%s commented on %s's post." % [comment['from']['name'], post_author]
    else
      header = "%s replied to %s's comment." % [comment['from']['name'], parent['from']['name']]
    end
    post_to_slack(header: header, quote: comment['message'], permalink: comment['permalink_url'], attachments: get_attachments(comment))
  end
end

def handle_comments comments, post_author
  case comments
  when Hash
    comments['data'].each do |comment|
      handle_comment comment, post_author
    end
    handle_comments(GRAPH.graph_call(*Koala::Facebook::API::GraphCollection.parse_page_url(comments['paging']['next'])), post_author) if comments.dig('paging', 'next')
  when Koala::Facebook::API::GraphCollection
    comments.each do |comment|
      handle_comment comment, post_author
    end
    handle_comments(comments.next_page, post_author)
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

  handle_comments post['comments'], post['from']['name']
end

files.each do |f|
  post_to_slack(header: "A file uploaded by #{f['from']['name']} can be downloaded here:", permalink: f['download_link'])
end

rescue => e
  SLACK.chat_postMessage(channel: USER_TO_NOTIFY, text: "```#{e.class}: #{e}\n#{e.backtrace.join("\n")}```", as_user: true)
end
