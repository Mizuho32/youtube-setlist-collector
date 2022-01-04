require 'yaml'

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

end
