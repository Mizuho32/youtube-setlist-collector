require 'fileutils'
require "csv"
require 'yaml'

require 'google/apis/sheets_v4'


module SheetsUtil
  extend self
  S = Google::Apis::SheetsV4

  def get_sheet(json_path)
    sheet = Google::Apis::SheetsV4::SheetsService.new
    authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: File.open(json_path),
      scope: %w(
        https://www.googleapis.com/auth/drive
        https://www.googleapis.com/auth/drive.file
        https://www.googleapis.com/auth/spreadsheets
      )
    )
    authorizer.fetch_access_token!
    sheet.authorization = authorizer

    return sheet
  end

  def request!(sheet, sheet_id, requests)
    request_body = Google::Apis::SheetsV4::BatchUpdateSpreadsheetRequest.new(requests: requests)
    sheet.batch_update_spreadsheet(sheet_id, request_body)
  rescue Google::Apis::ClientError => e
      puts "ERROR", (JSON.parse(e.body)["error"] rescue e.body)
      puts e.backtrace.select{|line| !line.include?("bundle")}.join("\n")
  end

  def insert!(sheet, sheet_id, gid, start_index, length, dimension: "ROWS")
    requests = [insert_dimension: Google::Apis::SheetsV4::InsertDimensionRequest.new(
                  range: Google::Apis::SheetsV4::DimensionRange.new(sheet_id: gid, dimension: dimension, start_index: start_index, end_index: start_index+length),
                  inherit_from_before: true)]
    request!(sheet, sheet_id, requests)
  end

  #                                                                                                 for each COLUMNS
  def merge!(sheet, sheet_id, gid, start_row_index, start_column_index, height, width, merge_type: "MERGE_COLUMNS")
    end_row_index = start_row_index + height
    end_column_index = start_column_index + width
    requests = [merge_cells: Google::Apis::SheetsV4::MergeCellsRequest.new(
      range: S::GridRange.new(sheet_id: gid, start_row_index: start_row_index, end_row_index: end_row_index, start_column_index: start_column_index, end_column_index: end_column_index),
      merge_type: merge_type)]
    request!(sheet, sheet_id, requests)
  end

  def reject_recur(hash, &block)
    hash.reject!{|k,v|
      if v.is_a?(Hash) then
        reject_recur(v, &block)
      end
      next true if block.call(k, v)
      false
    }
  end

=begin
  values = [{
    user_entered_format: {text_format: {font_size: 11, bold: true, foreground_color: {red:0, green:0, blue:0 }} },
    user_entered_value: { "formula_value": %Q{=HYPERLINK("https://google.com", "AOOGLE")}  },
  }]*2

  start = {sheet_id: 0, column_index: 0, row_index: 1}
  rows = [{values: values}]*3

  requests.push({
      update_cells: {
          fields: "*",
          start: start,
          rows: rows
      }
  })
=end

  def color(r,g,b,a=1)
    S::Color.new(red: r, green: g, blue: b, alpha: a)
  end

  def color_style(color)
    S::ColorStyle.new(rgb_color: color)
  end

  def if_not_nil(v, &block)
    return v if v.nil?
    return block.call(v)
  end

  def formatted_cell(value, font_size: 10, bold: false, foreground_color: [0, 0, 0], background_color: [1, 1, 1],
                     vertical_alignment: nil, horizontal_alignment: nil,
                     # TOP,MIDDLE,BOTTOM  LEFT,CENTER,RIGHT
                     borders: nil, # { top,bottom,leftr,right: {
                     # style: https://developers.google.com/sheets/api/reference/rest/v4/spreadsheets/cells#Style,
                     # color_style: color_style(color) }}
                     wrap_strategy: nil)
                     # OVERFLOW_CELL, LEGACY_WRAP, CLIP, WRAP
    value_type =
    case (value||true)
      when String
        if value =~ /^=/ then
          :formula
        else
          :string
        end
      when Numeric
        :number
      when TrueClass
        :bool
    end

    align = {vertical_alignment: vertical_alignment, horizontal_alignment: horizontal_alignment, wrap_strategy: wrap_strategy}.select{|k,v| v}
    data = { user_entered_value:  if_not_nil(value) {|value| S::ExtendedValue.new("#{value_type}_value": value)},
      user_entered_format: S::CellFormat.new(
        text_format: S::TextFormat.new(font_size: font_size, bold: bold, foreground_color: foreground_color && color(*foreground_color)),
        borders: borders && S::Borders.new(**Hash[borders.map{|k,v| [k, S::Border.new(**v)] }]),
        background_color: background_color && color(*background_color),
        **align) }

    reject_recur(data){|k, v| v.nil?}
    return data
  end

  def cellsmat2cells(cells_mat)
    cells_mat.map{|row| {values: row}}
  end

  def update_cells!(sheet, sheet_id, gid, row_index, column_index, cells)
    requests = [update_cells: S::UpdateCellsRequest.new(
      fields: "user_entered_value,user_entered_format",
      start: S::GridCoordinate.new(sheet_id: gid, row_index: row_index, column_index: column_index),
      rows: cells)]
    request!(sheet, sheet_id, requests)
  end

  def add_banding!(sheet, sheet_id, gid, row_index, column_index, horizontal_size, header_color, first_color, second_color, banded_range_id: 0)
    range = S::GridRange.new(sheet_id: gid, start_row_index: row_index, start_column_index: column_index, end_column_index: column_index+horizontal_size)
    hcolor = color(*htmlcolor(header_color || "#ffffff"))
    fcolor = color(*htmlcolor(first_color))
    scolor = color(*htmlcolor(second_color))

    bprop = S::BandingProperties.new(header_color: hcolor, first_band_color: fcolor, second_band_color: scolor)
    requests = [add_banding: S::AddBandingRequest.new(banded_range: S::BandedRange.new(banded_range_id: banded_range_id, range: range, row_properties: bprop))]
    request!(sheet, sheet_id, requests)
  end

  def insert_video!(sheet, sheet_id, gid, row_index, column_index, video, tindex, font_size,
                    bilingual: true,
                    title_back_colors: [htmlcolor("ffffff"), htmlcolor("000000")], title_fore_colors: [htmlcolor("ffffff"), htmlcolor("000000")],
                    row_back_colors: [])

    setlist = video[:setlist]
    length = setlist.size
    id = video[:id]


    # insert and merge cell for video title
    insert!(sheet, sheet_id, gid, row_index, length)
    merge!(sheet, sheet_id, gid, row_index, column_index, length, 1)

    # video title
    date = video[:published_at][/^([^T]+)T/, 1].gsub(?-,?/)
    url = %Q{=HYPERLINK("https://www.youtube.com/watch?v=#{id}","#{video[:title]}\n#{date}")}
    cells = cellsmat2cells([[
      formatted_cell(url, foreground_color: title_fore_colors[tindex%title_fore_colors.size], background_color: title_back_colors[tindex%title_back_colors.size],
                          horizontal_alignment: "CENTER", vertical_alignment: "MIDDLE",
                          wrap_strategy: "WRAP", font_size: font_size, bold: true) ]*2])
    update_cells!(sheet, sheet_id, gid, row_index, column_index, cells)

    row_back_color = row_back_colors[tindex%row_back_colors.size]
    # setlist
    cells = cellsmat2cells(setlist.each_with_index.map{|el, i|
      timesec = timestamp2int(el[:time])
      # FIXME?: english only
      name, name_en, artist, artist_en = el[:body][:song_name].to_s, el[:body][:song_name_en].to_s, el[:body][:artist].to_s, el[:body][:artist_en].to_s

      url = %Q{=HYPERLINK("https://www.youtube.com/watch?v=#{id}&t=#{timesec}","#{name}")}
      name_en = %Q{=HYPERLINK("https://www.youtube.com/watch?v=#{id}&t=#{timesec}","#{name_en}")} if not name_en.empty?

      namecell = formatted_cell(url, foreground_color: [0,0,0], background_color: row_back_color,
                                wrap_strategy: "CLIP", font_size: font_size, bold: true)
      namecell_en = formatted_cell(name_en, foreground_color: [0,0,0], background_color: row_back_color,
                                wrap_strategy: "CLIP", font_size: font_size, bold: true)

      artistcell = formatted_cell(artist, foreground_color: [0,0,0], background_color: row_back_color,
                                  wrap_strategy: "CLIP", font_size: font_size, bold: true)
      artistcell_en = formatted_cell(artist_en, foreground_color: [0,0,0], background_color: row_back_color,
                                  wrap_strategy: "CLIP", font_size: font_size, bold: true)

      comment = formatted_cell(el[:lines][1..-1]&.join("\n").to_s, foreground_color: [0,0,0], background_color: row_back_color,
                                  wrap_strategy: "CLIP", font_size: font_size, bold: true)

      if bilingual then
        [namecell, namecell_en, artistcell, artistcell_en, comment]
      else
        [namecell, artistcell, comment]
      end
    })
    update_cells!(sheet, sheet_id, gid, row_index, column_index+1, cells)
  end

  def timestamp2int(time)
    time.split(?:).reverse.each_with_index.map{|el, i| el.to_i * 60**i}.sum
  end

  def htmlcolor(code, alpha=1)
    [*code.sub(?#, "").each_char.each_slice(2).map{|c| (c.join.to_i(16)/255.0).round(7) }, alpha]
  end

  def color2hexcolor(rgb_color)
    %w[red green blue].map{|c| "%x" % (rgb_color.send(c) * 0xFF).to_i }.join
  end

  # query: hex num, candidates: [hex num,...]
  def nearest_color_index(query, candidates)
    candidates.map{|color| (color-query).abs}
      .each_with_index.min_by{|abs_val, i| abs_val}.last
  end

  #                     Hash,           Google::Apis::SheetsV4::Color
  def next_color_index(sheet_conf, background_color)
    query = color2hexcolor(background_color).to_i(16)
    cand  = sheet_conf[:rbc].map{|hex_str| hex_str.sub(?#, "").to_i(16) }

    return (nearest_color_index(query, cand).succ) % cand.size
  end


end
