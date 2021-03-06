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
require_relative "util"

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
$symbol_reg = /[#{Regexp.escape($symbol)}]|#{Moji.regexp(Moji::ZEN_SYMBOL)}|　/ # FIXME? Zenkaku space is symbol?

$time_reg = /(?:\d+:)+\d+/
# line that has timestamp in first row, no time stamp nor symbol only line follows
$line_reg = /[^\n]*#{$time_reg}[^\n]+(?:\n(?!(?:.+#{$time_reg}.+|(?:#{$symbol_reg})+))[^\n]+)*/
def list_reg_gen(lfnum)
  /(?:#{$line_reg}(?:\n){0,#{lfnum}}){2,}/ # TODO: auto detect num of LF
end
$list_reg = list_reg_gen(2)

$line_ignore_reg = /start|スタート/i
$ignore_reg = /^\s*\d+(?:\.|\s)/

class Array
  def mean()
    self.sum/self.size.to_f
  end
end

def get_setlist(text_original, song_db, select_thres = 0.5)
  lfnum = text_original.scan(/\n+/).map{|lfs| lfs.size}.mean.round # Line Feed
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
      .first.split(splt_reg).map(&:strip)
      #.select{|splt| not splt.empty? and splt !~ /^(?:\s|#{$symbol_reg})+$/ }
      # FIXME: remove symbol and space only item but not needed?
  }

  # map song_name and artist
  indices = indices_of_songinfo(song_db, tmp_setlist)
  setlist = tmp_setlist.each{|line| line[:body] =  splitted2songinfo(line[:splitted], indices, song_db) }

  return setlist, text_original, splitters

rescue StandardError => ex
  puts "FAILED while parsing", ex.backtrace.join("\n"), ex.message, "---", text_original
  #pp tmp_setlist
  raise Types::SetlistParseError.new(nil, tmp_setlist, text_original, ex)
end

def get_split_symbols(tmp_setlist, select_thres)
  lines = tmp_setlist.map{|el| el[:lines][0]}
  symbol_group = lines
    .map{|line| line.scan(/(?:(?!\s+[a-z])(?:\s|#{$symbol_reg})+|By)/i).uniq } # 単語間のスペースを拾わない
    .flatten.map{|s| s.strip}.group_by{|k,v| k}

  if symbol_group.empty? then # Zenkaku symbols
    symbol_group = lines
      .map{|line|
        # Zenkaku symbol substrings
        line.each_char.chunk{|char| Moji.type?(char, Moji::ZEN_SYMBOL)}.select{|is_symbol, chars| is_symbol}.map{|_, chars| chars.join}.uniq
      }.flatten.group_by{|k,v| k}
  end

  symbol_group_stat = Hash[symbol_group.map{|k,v| [k, v.size.to_f]}]
  dels = symbol_group_stat.keys.combination(2).map{|k1, k2|
    broad, narrow = if k1.include?(k2) then
      [k2, k1]
    elsif k2.include?(k1) then
      [k1, k2]
    else
      next
    end

    symbol_group_stat[narrow.gsub(broad, "")] = symbol_group_stat[narrow]
    symbol_group_stat[broad] += symbol_group_stat[narrow]
    narrow
  }.uniq
  dels.each{|k| symbol_group_stat.delete(k)}

  symbol_group_stat
    .select{|k,n|
      next(true) if /\(|\)/ =~ k  # special case of paren ()
      n/lines.size > select_thres
    }.keys.map(&:strip).select{|el| not el.empty?}.uniq
end

# ex. tmpsetlist -> {song_name: [0], artist: [1]}, indices array [0], [1] includes likelyhood indices
def indices_of_songinfo(song_db, tmp_setlist, sample_rate: 0.7, max_sample: 50)
  len = (tmp_setlist.size*sample_rate).to_i
  len = [tmp_setlist.size, max_sample].min if len > max_sample

  # search column indices in song_db
  info_indices = tmp_setlist[0...len].inject({}){|h, el|
    el[:splitted].each_with_index do |info, i| # info: songname or artist?, i: column index
      %i[song_name artist].each{|info_type|
        db = song_db[info_type]
        idx = db.index(info.strip.downcase)
        h[info_type] = (h[info_type] or []) << i if not idx.nil? # if in the db, insert column idx
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

  song_name_idx, song_name = Util.estim_song_name(song_name_idx, song_name, artist, splitted, song_db)
  artist_idx, artist = Util.estim_artist(song_name, artist, song_name_idx, artist_idx, splitted, song_db)

  if artist.object_id == song_name.object_id then
    if song_name_idx < artist_idx then
      song_name, artist = splitted.first, splitted.last
    else
      song_name, artist = splitted.last, splitted.first
    end
  end

  body = {song_name: song_name.to_s.strip, artist: artist.to_s.strip}

  # looks multilingual?
  if splitted.size > 2 then
    return Util.estim_en(song_name_idx, artist_idx, splitted, body)
  else
    return body
  end

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
def channel2setlists(youtube, sheet, channel_url, song_db, singing_streams:nil, title_match:nil, id_match:nil, range:0..-1, force: false, show_text_original: false, force_cache_comment: false, select_only: false)
  singing_streams = singing_streams.nil? ? $singing_streams : /#{singing_streams}|(?:#{$singing_streams})/
  channel_id = YTU.url2channel_id(channel_url)
  data_dir = Pathname(YTU::DATA_DIR)
  channel_dir = data_dir / channel_id

  # load singing streams
  csv_format = YTU::UPLOADS_CSV_FORMAT
  uploads = Util.filter_videos(Util.load_videos(channel_id), singing_streams, title_match: title_match, id_match: id_match, range: 0..-1)

  if not sheet.nil? then
    # calc delta
    ## get last title cell
    sc = sheet_conf = Util.sheet_conf(channel_id)

    ranges = ["SETLIST!R#{sc[:start_row].succ}C#{sc[:start_column].succ}"] #FIXME: SETLIST
    title_cell = sheet.get_spreadsheet(sc[:sheet_id], ranges: ranges, include_grid_data: true)
      .sheets.first.data.first.row_data.first.values.first
    range = Util.yet_uploaded_videos?(uploads, title_cell.hyperlink[/v=([^=]+)/, 1]) if range.nil?
  end

  uploads = uploads[range]


  puts "SELECTED:", "---", uploads.map{|line| "#{line[csv_format[:title]]} (#{line[csv_format[:id]]})" }.join("\n"), "---"
  return if select_only

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
  rescue Google::Apis::ClientError => ex
    STDERR.puts ex.message
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
  channel_id, singing_streams:nil, title_match:nil, id_match:nil, range: nil, tindex: nil,
  sleep_interval: 0.5, select_only: false)

  # get last title cell
  sc = sheet_conf = Util.sheet_conf(channel_id)

  ranges = ["SETLIST!R#{sc[:start_row].succ}C#{sc[:start_column].succ}"]
  #FIXME: SETLIST
  title_cell = sheet.get_spreadsheet(sc[:sheet_id], ranges: ranges, include_grid_data: true)
    .sheets.first.data.first.row_data.first.values.first

  tindex = SheetsUtil.next_color_index(sc, title_cell.effective_format.background_color) if tindex.nil?

  singing_streams = singing_streams.nil? ? $singing_streams : /#{singing_streams}|#{$singing_streams}/
  csv_format = YTU::UPLOADS_CSV_FORMAT

  # select singing_streams
  selected = Util.filter_videos(Util.load_videos(channel_id), singing_streams, title_match: title_match, id_match: id_match, range: 0..-1)

  # compare sheet's latest and cached streams and calc delta
  range = Util.yet_uploaded_videos?(selected, title_cell.hyperlink[/v=([^=]+)/, 1]) if range.nil?

  #selected = CSV.read(channel_dir / YTU::UPLOADS_CSV)
  #    .select{|line|
  #      title = line[csv_format[:title]]
  #      id = line[csv_format[:id]]
  #      title.match(singing_streams) and (
  #        (not !title_match.nil? or title.match(title_match)) and # not nil? -> match
  #        (not !id_match.nil?    or id.match(id_match))          )
  #    }[range]

  puts <<-EOO
tindex: #{tindex}
SELECTED:
---
#{selected[range].each_with_index.map{|line, i| "#{i}. #{line[csv_format[:title]]} (#{line[csv_format[:id]]})" }.join("\n")}
---
EOO

  return if select_only

  selected = selected[range]

  %i[tbc tfc rbc].each{|key| sheet_conf[key] = sheet_conf[key].map{|color| SheetsUtil.htmlcolor(color)} }
  streams_dir = Util.streams_dir(channel_id)

  req_per_loop = 4
  req_limit = 60 # / min

  # write to sheet
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
    SheetsUtil.insert_video!(sheet, sc[:sheet_id], sc[:gid], sc[:start_row], sc[:start_column], video, tindex+i,
                     title_back_colors: sc[:tbc], title_fore_colors: sc[:tfc])
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
                            sc[:header_color], sc[:rbc][0], sc[:rbc][1])

    puts "Sheet ID is #{sheet_id}, url is #{sheet_url}"
    row << sheet_id
    row << sheet_url

    # Save conf
    CSV.open(PY::DATA_DIR / PY::CHANNELS_CSV, "wb") do |csv|
      channels_csv.uniq.each{|r| csv << r }
    end

    File.write(channel_dir / Params::Sheet::SHEET_CONF, sc.to_yaml)
end
