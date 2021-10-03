# coding: utf-8

require 'csv'
require 'pp'
require 'yaml'

require 'nkf'
require 'moji'

require_relative "params"
require_relative "types"
require_relative "sheet"
require_relative "youtube_utils"
require_relative "drive"

#load "src/types.rb" # FIXME
#load "src/youtube_utils.rb"

PY = Params::YouTube
CE = Google::Apis::ClientError

def item2snippet(item)
  return item.snippet.top_level_comment.snippet
end

def item2text_orig(item)
  return item.snippet.top_level_comment.snippet.text_original
end

def preprocess(text_original)
  NKF::nkf("-wZ0", text_original.gsub(/\r/, ""))
end

$japanese_regex = /(?:\p{Hiragana}|\p{Katakana}|[ー－]|[一-龠々])/

$setlist_reg = /(?:set|songs?|セッ?ト|曲).*(?:list|リ(スト)?)/i
$symbol = %Q<!@#$%^&*()_+-=[]{};':"\\,|.<>/?〜>
$symbol_reg = /[#{Regexp.escape($symbol)}]|#{Moji.regexp(Moji::ZEN_SYMBOL)}/

$time_reg = /(?:\d+:)+\d+/
# line that has timestamp in first row, no time stamp nor symbol only line follows
$line_reg = /[^\n]*#{$time_reg}[^\n]+(?:\n(?!(?:.+#{$time_reg}.+|(?:#{$symbol_reg})+))[^\n]+)*/
def list_reg_gen(lfnum)
  /(?:#{$line_reg}(?:\n){0,#{lfnum}}){2,}/ # TODO: auto detect num of LF
end
$list_reg = list_reg_gen(2)

$line_ignore_reg = /start|スタート/i
$ignore_reg = /(?:^\s*\d+(?:\.|\s)|　)/

class Array
  def mean()
    self.sum/self.size.to_f
  end
end

def get_setlist(text_original, song_db, select_thres = 0.5)
  lfnum = text_original.scan(/\n+/).map{|lfs| lfs.size}.mean.to_i
  list_reg = list_reg_gen(lfnum)
  m = if $setlist_reg =~ text_original then
    text_original.split($setlist_reg).map{|e| e.match(list_reg)}.compact.first
  else
    text_original.match(list_reg)
  end

  return [], text_original, [] if m.nil?

  tmp_setlist = m[0]
    .strip.scan($line_reg)
    .select{|el| not el.match($line_ignore_reg) }
    .map{|el|
      time = el.scan($time_reg).first # FIXME?
      m = el.sub($ignore_reg, "").split($time_reg).map(&:strip) # split by timestamp
      return [], text_original, [] if m.empty?

      body = m.first.size > m.last.size ? m.first : m.last
      { time: time,
        lines: lines=body.split("\n").map{|line| line.strip}
      }
    }

  # find splitter and split body by splitter
  j = $japanese_regex
  splitters = get_split_symbols(tmp_setlist, select_thres)
  splt_reg = splitters.map{|e|
    next "(?:(?<![a-z0-9,.]|#{j.to_s})#{e}|#{e}(?![a-z0-9]|#{j.to_s}))" if e =~ /^\s+$/
    Regexp.escape(e)
  }
  splt_reg = splitters.empty? ? /$/ : /(?:#{ splt_reg.join("|") })/i
  tmp_setlist.select!{|el| el[:lines].first.match(splt_reg) }
  tmp_setlist.each{|el|
    el[:splitted] = el[:lines]
      .first.split(splt_reg)
      .select{|splt| not splt.empty? and splt !~ /^(?:\s|#{$symbol_reg})+$/ }
  }
  # map song_name and artist
  indices = indices_of_songinfo(song_db, tmp_setlist)
  setlist = tmp_setlist.each{|line| line[:body] =  splitted2songinfo(line[:splitted], indices, song_db) }
  return setlist, text_original, splitters
rescue StandardError => ex
  puts "FAILED while parsing", ex.message, "---", text_original
  #pp tmp_setlist
  raise Types::SetlistParseError.new(nil, tmp_setlist, text_original, ex)
end

def get_split_symbols(tmp_setlist, select_thres)
  lines = tmp_setlist.map{|el| el[:lines][0]}
  symbol_group = lines
    .map{|line| line.scan(/(?:(?!\s+[a-z])(?:\s|#{$symbol_reg})+|By)/i).uniq }
    .flatten.group_by{|k,v| k}

  if symbol_group.empty? then # Zenkaku symbols
    symbol_group = lines
      .map{|line|
        # Zenkaku symbol substrings
        line.each_char.chunk{|char| Moji.type?(char, Moji::ZEN_SYMBOL)}.select{|is_symbol, chars| is_symbol}.map{|_, chars| chars.join}.uniq
      }.flatten.group_by{|k,v| k}
  end

  symbol_group_stat = Hash[symbol_group.map{|k,v| [k, v.size.to_f]}]
  symbol_group_stat.keys.combination(2).each{|k1, k2|
    if k1.include?(k2) then
      symbol_group_stat[k2] += symbol_group_stat[k1]
    elsif k2.include?(k1) then
      symbol_group_stat[k1] += symbol_group_stat[k2]
    end
  }
  symbol_group_stat.select{|k,n| n/lines.size > select_thres}.keys
end

def indices_of_songinfo(song_db, tmp_setlist, sample_rate: 0.7, max_sample: 50)
  len = (tmp_setlist.size*sample_rate).to_i
  len = [tmp_setlist.size, max_sample].min if len > max_sample

  # search indices in song_db
  info_indices = tmp_setlist[0...len].inject({}){|h, el|
    el[:splitted].each_with_index do |info, i|
      %i[song_name artist].each{|info_type|
        db = song_db[info_type]
        idx = db.index(info.strip.downcase)
        h[info_type] = (h[info_type] or []) << i if not idx.nil?
        #h[:splitted] = el[:splitted]
      }
    end
    h
  }
  #p "info", info_indices

  # calc statistics
  info_indices.map{|info_type, idx|
    idx_distri = idx
      .group_by(&:itself)
      .map{|idx, amount| [idx, amount.size]}
      .sort{|(lidx, lsize),(ridx, rsize)| lsize <=>rsize}.reverse
    [info_type, idx_distri.map{|(idx, size)| idx}]
  }.to_h
end

# FIXME song_name, artist search using song_db should improved
def splitted2songinfo(splitted, indices, song_db)
  song_name_idx = indices[:song_name]&.first || splitted.size
  artist_idx    = indices[:artist]&.first || splitted.size
  song_name = splitted[song_name_idx]
  artist    = splitted[artist_idx]

  if song_name.nil? then
    _splitted = splitted.reject{|n| n==artist}
    if song_name_idx >= _splitted.size # invalid song_name index
      if _splitted.size==1
        song_name = _splitted.first
      else
        if not (searched = _splitted.select{|itm| song_db[:song_name].index(itm.downcase)}).empty?
          song_name = searched.first
        else
          song_name = _splitted.first
        end
      end
    else
      song_name = if song_name_idx < artist_idx then
        _splitted.first
      else
        _splitted.last
      end
    end
  end

  if artist.nil?
    if splitted.size != 1
      artist = if song_name_idx < artist_idx then
        splitted.last
      else
        splitted.first
      end
    else
      if idx = song_db[:song_name].index(song_name.downcase) then
        artist = song_db[:ARTIST][idx]
      end
    end
  end


  return {song_name: song_name.to_s.strip, artist: artist.to_s.strip}
end


def get_song_db(csv_location)
return CSV.read(csv_location)[1..]
    .reject{|el| el.compact.empty? }
    .inject({song_name: [], artist:[], SONG_NAME: [], ARTIST:[]}){|h, row|
        h[:song_name] << row.first.downcase
        h[:artist] << row.last.downcase
        h[:SONG_NAME] << row.first # FIXME
        h[:ARTIST] << row.last
        h
    }
end

def looks_comment_setlist?(text_original)
  text_original.match($setlist_reg) or text_original.match($list_reg)
end

def video2looks_setlists(youtube, videoId: "", maxResults: 20, response: nil, show: false, force_cache: false)
  response = youtube.list_comment_threads('snippet', video_id: videoId.to_s, max_results: maxResults, order: "relevance") if response.nil? or force_cache

  lsl = response.items.map{|el|
    [el, preprocess( item2text_orig(el) )]
  }.select{|el, text_original|
    looks = looks_comment_setlist?(text_original)
    if show then
      puts "-----", text_original, "match list_reg: #{!! looks}"
    end
    looks
  }.sort{|(lel,ltext_original), (rel,rtext_original)|
    lel.snippet.top_level_comment.snippet.like_count <=> rel.snippet.top_level_comment.snippet.like_count
  }.reverse
  return lsl, response
end

def video2setlist(youtube, song_db, videoId: "", maxResults: 20, response: nil, show: false, force_cache: false)
  looks_str_setlists, response = video2looks_setlists(youtube, videoId: videoId, maxResults: maxResults, response: response, show: show, force_cache: force_cache)

  set_list, txt, splitters = [], "", []
  looks_str_setlists.each{|el, text_original| # comment object, text
  begin
    txt = text_original
    set_list, text_original, splitters = get_setlist(text_original, song_db)
    break if not set_list.empty?
  rescue Types::SetlistParseError => ex
    ex.response = response
    raise ex
  end
  }
  raise Types::NoSetlistCommentError.new(response, txt) if set_list.empty?

  return set_list, txt, splitters, response
end

$singing_streams = /(?:歌枠|singing\s+stream)/i
def channel2setlists(youtube, channel_url, song_db, singing_streams:nil, title_match:nil, id_match:nil, range:0..-1, force: false, show_text_original: false, force_cache_comment: false)
  singing_streams = singing_streams.nil? ? $singing_streams : /#{singing_streams}|(?:#{$singing_streams})/
  channel_id = YTU.url2channel_id(channel_url)
  data_dir = Pathname(YTU::DATA_DIR)
  channel_dir = data_dir / channel_id

  # select singing streams
  csv_format = YTU::UPLOADS_CSV_FORMAT
  uploads = CSV.read(channel_dir / YTU::UPLOADS_CSV)
    .select{|line|
      title = line[csv_format[:title]]
      id = line[csv_format[:id]]
      title.match(singing_streams) and (
        (not !title_match.nil? or title.match(title_match)) and # not nil? -> match
        (not !id_match.nil?    or id.match(id_match))          )
    }[range]
  puts "SELECTED:", "---", uploads.map{|line| "#{line[csv_format[:title]]} (#{line[csv_format[:id]]})" }.join("\n"), "---"

  # make setlists
  streams_dir = data_dir / channel_id / YTU::STREAMS_DIR
  fails = uploads.map{|line|
  begin
    # If setlist yaml exists, return
    id = line[csv_format[:id]]
    title = line[csv_format[:title]]
    yamlfile_name = streams_dir / "#{id}.yaml"
    next if File.exist?(yamlfile_name) and not force

    # Load comment cache
    comment_cache = channel_dir / YTU::COMMENT_CACHE_DIR / "#{id}.yaml"
    cache = File.exist?(comment_cache) ? YAML.load_file(comment_cache) : {}
    response = cache[:response]

    # video id to setlist
    puts "Analyze #{title}(#{id})..."
    set_list, text, splitters, response = video2setlist(youtube, song_db, videoId: id, response: response, show: show_text_original, force_cache: force_cache_comment)
    yaml = {title: title, id: id, splitters: splitters, setlist: set_list, text_original: text}.to_yaml
    File.write(yamlfile_name, yaml) if not File.exist?(yamlfile_name) or force

    # Error handling
  rescue Types::SetlistParseError => ex
    File.write(comment_cache, {errmsg: ex.ex.message+"\n"+ex.ex.backtrace.join("\n"), response: ex.response, tmp_setlist: ex.tmp_setlist, text_original: ex.text_original}.to_yaml)
    next [title, id, ex.class.to_s]
  rescue Types::NoSetlistCommentError => ex
    puts msg="Setlist comment not found for #{title}(#{id})"
    puts ex.text_original
    File.write(comment_cache, {errmsg: msg, response: ex.response, text_original: ex.text_original}.to_yaml)
    next [title, id, ex.class.to_s]
  end
    File.write(comment_cache, {response: response}.to_yaml) if(not File.exist?(comment_cache) or force_cache_comment)
    nil
  }.compact

  CSV.open(channel_dir / YTU::FAILS_CSV, "wb") do |csv|
    fails.each{|row| csv << row }
  end
end


def insert_videos_to_sheet(sheet,
  # video select params
  channel_id, singing_streams:nil, title_match:nil, id_match:nil, range:0..-1,
  # sheet style params, 0 is true
  previous_setlist_even: 0,
  sleep_interval: 0.5)

  singing_streams = singing_streams.nil? ? $singing_streams : /#{singing_streams}|#{$singing_streams}/
  channel_dir = YTU::DATA_DIR / channel_id
  csv_format = YTU::UPLOADS_CSV_FORMAT

  selected = CSV.read(channel_dir / YTU::UPLOADS_CSV)
      .select{|line|
        title = line[csv_format[:title]]
        id = line[csv_format[:id]]
        title.match(singing_streams) and (
          (not !title_match.nil? or title.match(title_match)) and # not nil? -> match
          (not !id_match.nil?    or id.match(id_match))          )
      }[range]

  puts "SELECTED:", "---", selected.each_with_index.map{|line, i| "#{i}. #{line[csv_format[:title]]} (#{line[csv_format[:id]]})" }.join("\n"), "---"

  sc = sheet_conf = YAML.load_file(channel_dir / Params::Sheet::SHEET_CONF)
  %i[tbc tfc rbc].each{|key| sheet_conf[key] = sheet_conf[key].map{|color| SheetsUtil.htmlcolor(color)} }
  streams_dir = channel_dir / Params::YouTube::STREAMS_DIR

  req_per_loop = 4
  req_limit = 60 # / min

  start_time = Time.now
  req_count = 0
  selected.reverse.each_with_index{|row, i|
    if req_count + req_per_loop > req_limit then
      puts("Sleeping...")
      sleep( [60-(Time.now - start_time) + 5, 0].max )
      start_time = Time.now
      req_count = 0
    end
    req_count += req_per_loop


    yaml = streams_dir / (row[csv_format[:id]] + ".yaml")
    if not File.exist?(yaml) then
      puts "Skip #{row.join(" ")}"
      next
    end

    video = YAML.load_file(yaml)
  begin
    SheetsUtil.insert_video!(sheet, sc[:sheet_id], sc[:gid], sc[:start_row], sc[:start_column], video, i,
                     row_idx_offset: previous_setlist_even+video[:setlist].size%2, # FIXME
                     title_back_colors: sc[:tbc], title_fore_colors: sc[:tfc], row_back_colors: sc[:rbc])
    previous_setlist_even = video[:setlist].size % 2
    sleep sleep_interval
  rescue Google::Apis::RateLimitError => ex
    puts ex.message
    puts "Processing: #{row.join(", ")}"
    return
  end
  }
end

def init_sheet(drive, sheet, channel_id, templ_sheet_id, view_dir_id)
    p PY::DATA_DIR / PY::CHANNELS_CSV
    begin
      channels_csv = CSV.read(PY::DATA_DIR / PY::CHANNELS_CSV)
    rescue
      puts "Init project first"
      return
    end

    if (row = channels_csv.select{|row| row[PY::CHANNELS_CSV_FORMAT[:id]] == channel_id}.first).nil? then
      puts "Not found #{channel_id}"
      return
    end

    name, channel_id, sheet_id = row
    puts "Found #{name} (#{channel_id})"

    if not sheet_id.nil? then
      puts "Sheet #{sheet_id} already exists"
      return
    end

    # Sheet conf load
    channel_dir = PY::DATA_DIR / channel_id
    if not File.exist?(channel_dir / Params::Sheet::SHEET_CONF) then
      puts "No sheet.yaml config file"
      return
    end
    sc = sheet_conf = YAML.load_file(channel_dir / Params::Sheet::SHEET_CONF)

    copied = DriveUtil.copy_file(drive, templ_sheet_id, name, view_dir_id)
    sc[:sheet_id] = sheet_id = copied.id

    f = DriveUtil.make_shared(drive, sheet_id)
    sheet_url = f.web_view_link

    # start_row-1 is header location. and to void destroyed by inserting a new setlist
    SheetsUtil.add_banding!(sheet, sheet_id, sc[:gid], sc[:start_row]-1, sc[:start_column]+1, 2,
                            sc[:rbc][0], sc[:rbc][1])

    puts "Sheet ID is #{sheet_id}, url is #{sheet_url}"
    row << sheet_id
    row << sheet_url

    # Save conf
    CSV.open(PY::DATA_DIR / PY::CHANNELS_CSV, "wb") do |csv|
      channels_csv.uniq.each{|r| csv << r }
    end

    File.write(channel_dir / Params::Sheet::SHEET_CONF, sc.to_yaml)
end
