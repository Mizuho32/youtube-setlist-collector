require 'yaml'

require 'test/unit'
require 'pp'

#require_relative '../src/types'
require_relative '../src/lib'


class ParseTest < Test::Unit::TestCase
  self.test_order = :defined
  SELF=self

  class << self
    attr_accessor :song_db, :target_yaml

    def startup 
      puts "Start #{self}"
      @song_db = get_song_db("list.csv")
      @target_yaml = YAML.load_file("test/data/xSdb312w0gY.yaml")
    end
    
    def shutdown
      puts "End #{self}"
    end
  end


  test "incices_of_songname_and_artist" do
    indices = indices_of_songinfo(SELF.song_db, SELF.target_yaml[:setlist])

    # JP name, EN name, JP artist, EN artist
    assert_equal(0, indices[:song_name].first)
    assert_equal(2, indices[:artist].first)
  end

  test "EN/JP setlist" do
    indices = indices_of_songinfo(SELF.song_db, SELF.target_yaml[:setlist])

    SELF.target_yaml[:setlist].each{|item|
      splitted = item[:splitted]
      song = nil
      song_en = nil
      artist = nil
      artist_en = nil

      puts splitted.join(", ")

      if splitted.size == 3 then
        song, song_en, artist = splitted
      elsif splitted.size == 4 then
        song, song_en, artist, artist_en = splitted
      elsif splitted.size == 2 then
        song, artist = splitted
      end

      body = splitted2songinfo(splitted, indices, SELF.song_db)
      puts "  #{body.inspect}"

      assert_equal(song, body[:song_name])
      assert_equal(song_en, body[:song_name_en])
      assert_equal(artist, body[:artist])
      assert_equal(artist_en, body[:artist_en])
    }
  end

  #assert_nil(c.block)
end
