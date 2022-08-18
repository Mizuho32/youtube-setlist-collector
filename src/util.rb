require 'yaml'
require 'date'

require_relative "params"
require_relative "youtube_utils"

module Util
  extend self

  # for songs statistics
  def song_freq(ident)
    channel_id = YTU.url2channel_id(ident)

    all_songs = Dir.glob(YTU::DATA_DIR / channel_id / YTU::STREAMS_DIR / "*.yaml")
      .map{|path|
        path = Pathname(path)
        [path.basename(path.extname).to_s.to_sym, YAML.load_file(path)]
      }
      .map{|id, yaml| yaml[:setlist].map{|row| row[:body][:song_name]} }
      .flatten.map{|name| name.gsub(/\([^\)]+(\)|$)|(\(|^)[^\)]+\)/, "") }

    grouped_songs = all_songs.group_by{|song| song.downcase.gsub(/\s+/,"") }
    stat = grouped_songs.map{|name, freq| [freq.first, freq.size]}.sort{|(_,l),(_,r)| l<=>r}.reverse
  end

  def estim_en(song_name_idx, artist_idx, splitted, body) # FIXME: not only for EN
    pair = splitted.each_with_index
      .reject{|el, i| i == song_name_idx or i == artist_idx} # FIXME? in the case of song_name / | artist (artist_en)
      .map{|el, i| el}[0...2]

    if song_name_idx < artist_idx then
      return {**body, song_name_en: pair[0], artist_en: pair[1]}
    else
      return {**body, song_name_en: pair[1], artist_en: pair[0]}
    end
  end

  def estim_song_name(song_name_idx, song_name, artist, splitted, song_db)
    if song_name.nil? then
      _splitted = splitted.each_with_index
        .map{|el, i| [i, el]}
        .reject{|(i, n)| n==artist }

      if song_name_idx >= _splitted.size # invalid song_name index
        if _splitted.size==1
          _splitted.first
        else
          if not (searched = _splitted.select{|i, itm| song_db[:song_name].index(itm.downcase)}).empty?
            searched.first
          else
            _splitted.first
          end
        end
      else
        if song_name_idx < artist_idx then
          _splitted.first
        else
          _splitted.last
        end
      end
    else
      [song_name_idx, song_name]
    end
  end

  def estim_artist(song_name, artist, song_name_idx, artist_idx, splitted, song_db)
    splitted = splitted.each_with_index.map{|el, i| [i, el]}

    if artist.nil?
      if splitted.size != 1
        if song_name_idx < artist_idx then
          splitted.last
        else
          splitted.first
        end
      else
        if idx = song_db[:song_name].index(song_name.downcase) then
          [ -1, song_db[:ARTIST][idx] ]
        else
          [artist_idx, artist]
        end
      end
    else
      [artist_idx, artist]
    end
  end

  def channel_dir(channel_id)
    Params::DATA_DIR / channel_id
  end

  def streams_dir(channel_id)
    channel_dir(channel_id) / Params::YouTube::STREAMS_DIR
  end

  def sheet_conf(channel_id)
    YAML.load_file(channel_dir(channel_id) / Params::Sheet::SHEET_CONF)
  end

  def channel_infos(channel_id)
    channel = YAML.load_file(channel_dir(channel_id) / CHANNEL_INFO_YAML)
    uploads = CSV.read(channel_dir / UPLOADS_CSV) rescue []

    return channel, uploads
  end


  def load_videos(channel_id)
    CSV.read(channel_dir(channel_id) / YTU::UPLOADS_CSV)
  end

  def filter_videos(videos, main_filter, title_match:nil, id_match:nil, range:0..-1)
    csv_format = YTU::UPLOADS_CSV_FORMAT
    videos.select{|line|
        title = line[csv_format[:title]]
        id = line[csv_format[:id]]
        title.match(main_filter) and (
          (not !title_match.nil? or title.match(title_match)) and # not nil? -> match
          (not !id_match.nil?    or id.match(id_match))          )
      }[range]
  end

  def yet_uploaded_videos?(list, last_id)
    csv_format = YTU::UPLOADS_CSV_FORMAT
    arg = list.map{|row| row[csv_format[:id]]}.index(last_id)

    if arg.nil? then
      return 0...0
    else
      return 0...arg
    end
  end

  def load_uploades(youtube, channel_id)
    uploads = CSV.read(channel_dir(channel_id) / YTU::UPLOADS_CSV) rescue []
    fmt = YTU::UPLOADS_CSV_FORMAT

    # Date parse
    uploads.map!{|row|
      row[fmt[:date]] = DateTime.iso8601(row[fmt[:date]]) rescue false
      row
    }
    # Consistency check
    no_dates_idx = uploads.each_with_index.select{|row, i|
      not row[fmt[:date]]
    }.map{|row, i| i}

    ids = no_dates_idx.map{|i| uploads[i][fmt[:id]]}
    dates = YTU.get_video_details(youtube, ids)
      .map{|item| item.snippet.published_at.new_offset(Time.now.getlocal.zone)}

    no_dates_idx.each{|i|
      puts "#{i}, #{uploads[i]}, #{fmt[:date]}"
      uploads[i][fmt[:date]] = dates[i]}

    # Save
    save_uploads(channel_id, uploads) if not no_dates_idx.empty?

    return uploads
  end

  def save_uploads(channel_id, uploads)
    fmt = YTU::UPLOADS_CSV_FORMAT

    CSV.open(channel_dir(channel_id) / YTU::UPLOADS_CSV, "wb") { |csv|
      uploads.each do |row|
        row[fmt[:date]] = row[fmt[:date]].iso8601
        csv << row
      end
    }
  end

  def map_recur(hash, &block)
    return Hash[hash.map{|k,v|
      if v.is_a?(Hash) then
        [k, map_recur(v, &block)]
      else
        mapped = block.call(k, v)
        if mapped.is_a? Array then
          mapped
        else
          [k, v]
        end
      end
    }]
  end



end
