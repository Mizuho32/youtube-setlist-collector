require 'fileutils'
require "csv"
require 'yaml'

require 'google/apis/youtube_v3'

module YTU
  extend self
  CHANNELS_CSV = "channels.csv"
  CHANNEL_INFO_YAML = "info.yaml"
  UPLOADS_CSV = "uploads.csv" # title, id, status
  UPLOADS_CSV_FORMAT = %i[title id status].each_with_index.map{|e,i| [e, i]}.to_h

  DATA_DIR = "data"
  CACHE_DIR = "cache"
  STREAMS_DIR = "singing_streams"
  COMMENT_CACHE_DIR = Pathname(CACHE_DIR) / "comment"

  MAX_RESULTS = 50

  def url2channel_id(url)
    url[%r|youtube\.com/c(?:hannel)?/(?<id>[^/]+)/videos|, :id]
  end

  def init_project(youtube, channel_url, data_dir: Pathname(DATA_DIR))
    FileUtils.mkdir(data_dir) if not Dir.exist?(data_dir)
     
    channels_csv = CSV.read(data_dir / CHANNELS_CSV) rescue []
    channel_id = url2channel_id(channel_url)

    if not (hit=channels_csv.select{|(title, chid)| chid == channel_id}).empty? then
      STDERR.puts "WARN: Channel #{channel_url} already exists!"
    end

    channels = youtube.list_channels("snippet,contentDetails", id: channel_id)
    if channels.items.empty? then
      STDERR.puts "Invalid channel #{channel_url}"
      return 2
    end

    channel = channels.items.first
    channel_title = channel.snippet.title
    channels_csv << [channel_title, channel_id]

    CSV.open(data_dir / CHANNELS_CSV, "wb") do |csv|
      channels_csv.each{|row| csv << row }
    end if not Dir.exist?(data_dir / CHANNELS_CSV)


    channel_dir = data_dir / channel_id
    FileUtils.mkdir(channel_dir) if not Dir.exist?(channel_dir)
    FileUtils.mkdir(channel_dir / STREAMS_DIR) if not Dir.exist?(channel_dir / STREAMS_DIR)
    FileUtils.mkdir(channel_dir / CACHE_DIR) if not Dir.exist?(channel_dir / CACHE_DIR)
    FileUtils.mkdir(channel_dir / COMMENT_CACHE_DIR) if not Dir.exist?(channel_dir / COMMENT_CACHE_DIR)
    File.write(channel_dir / CHANNEL_INFO_YAML, channel.to_yaml) if not Dir.exist?(channel_dir / CHANNEL_INFO_YAML)

    get_uploads(youtube, channel_id, channel: channel)
  end

  def get_uploads(youtube, channel_id, data_dir: Pathname(DATA_DIR), channel: nil)
    channel_dir = data_dir / channel_id
    channel = YAML.load_file(channel_dir / CHANNEL_INFO_YAML) if channel.nil?

    channel_stat = youtube.list_channels("statistics", id: channel_id).items.first

    video_count = channel_stat.statistics.video_count
    uploads = CSV.read(channel_dir / UPLOADS_CSV) rescue []
    playlist_id = channel.content_details.related_playlists.uploads

    uploads =
    if uploads.empty? then
      load_uploads(youtube, video_count, playlist_id)
    elsif uploads.size < video_count then
      load_uploads(youtube, video_count-uploads.size, playlist_id)
    elsif uploads.size > video_count then
      raise NotImplementedError.new
    else # uploaded == cached
      return
    end + uploads

    CSV.open(channel_dir / UPLOADS_CSV, "wb") do |csv|
      uploads.each{|row| csv << row }
    end
  end

  def load_uploads(youtube, count, playlist_id)
    max_result = count > MAX_RESULTS ? MAX_RESULTS : count

    uploads = []
    token = nil
    loop do
      playlist = youtube.list_playlist_items("snippet,contentDetails", playlist_id: playlist_id, page_token: token, max_results: max_result)
      uploads += playlist.items.map{|v| [v.snippet.title, v.content_details.video_id, "public"] }
      token = playlist.next_page_token
      break if token.nil?
    end
    
    return uploads
  end
end
