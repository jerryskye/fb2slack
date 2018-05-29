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
Koala.config.api_version = 'v3.0'
LOGGER = Logger.new ARGV[1], 'daily'
Koala::Utils.logger = LOGGER
GRAPH = Koala::Facebook::API.new config['fb_access_token']
CHANNEL = config['slack_channel']
GROUP_ID = config['fb_group_id']
USER_TO_NOTIFY = config['slack_user_to_notify']

def post_to_slack hsh
  SLACK.chat_postMessage({channel: CHANNEL, as_user: true, unfurl_links: false}.merge(hsh))
end

def get_attachments post
  (if post['attachments']
    post['attachments']['data'].map do |attachment|
      case attachment['type']
      when 'photo'
        {text: 'Photo', image_url: attachment['media']['image']['src']}
      when 'album'
        (attachment['subattachments']['data'].each_with_index.map {|sub, i| {text: "Photo #{i}", image_url: sub['media']['image']['src']}})
      when 'file_upload'
        {title: 'File upload', title_link: attachment['url']}
      end
    end.flatten
  elsif post.has_key? 'attachment'
    case post.dig('attachment', 'type')
    when 'photo'
      [{text: 'Photo', image_url: post.dig('attachment', 'media', 'image', 'src')}]
    when 'animated_image_share'
      [{text: 'GIF', image_url: post.dig('attachment', 'url')}]
    end
  else
    case post['type']
    when 'photo'
      [{text: 'Photo', image_url: GRAPH.get_object(post['object_id'], fields: 'images')['images'].first['source']}]
    when 'link'
      [{title: "Link: #{post['description']}", title_link: post['link']}]
    end
  end) || Array.new
end

def handle type, entry
  if DateTime.parse(entry['created_time']) > LAST_CHECK
    attachment = case type
                 when :post
                   {fallback: (entry['story'] || 'Somebody posted'), title: (entry['story'] || 'Somebody posted')}
                 when :comment
                   parent_comment = entry['parent']
                   title = if parent_comment.nil?
                             "Somebody commented on somebody's post"
                           else
                             "Somebody replied to somebody's comment"
                           end
                   {fallback: title, title: title}
                 end.merge({title_link: entry['permalink_url'], text: entry['message']})
    post_to_slack(attachments: get_attachments(entry).unshift(attachment))
  end
end

def handle_comments comments
  case comments
  when Hash
    comments['data'].each do |comment|
      handle :comment, comment
    end
    handle_comments(GRAPH.graph_call(*Koala::Facebook::API::GraphCollection.parse_page_url(comments['paging']['next']))) if comments.dig('paging', 'next')
  when Koala::Facebook::API::GraphCollection
    comments.each do |comment|
      handle :comment, comment
    end
    handle_comments(comments.next_page)
  end
end

feed = GRAPH.get_object(GROUP_ID + '/feed', {since: LAST_CHECK.to_s,
  fields: 'message,object_id,updated_time,created_time,type,story,from,permalink_url,comments.filter(stream){created_time,message,from,permalink_url,parent,attachment},link,description,caption'})
files = GRAPH.get_object(GROUP_ID + '/files', {since: LAST_CHECK.to_s, fields: 'download_link,updated_time,from'})

LOGGER.info 'feed.count: %d' % feed.count

unless feed.empty?
  config['last_check'] = DateTime.parse(feed.first['updated_time'])
  LOGGER.info "inserting #{config['last_check']} into last_check"
  File.write(ARGV.first, YAML.dump(config))
end

feed.each do |post|
  handle :post, post
  handle_comments post['comments']
end

files.each do |f|
  post_to_slack(attachments: [{title: 'File upload by somebody', title_link: f['download_link']}])
end

rescue => e
  post_to_slack(channel: USER_TO_NOTIFY, text: "```#{e.class}: #{e}\n#{e.backtrace.join("\n")}```", as_user: true)
end
