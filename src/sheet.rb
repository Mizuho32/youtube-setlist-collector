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

	def	formatted_cell(value, font_size: 10, bold: false, foreground_color: [0, 0, 0], background_color: [1, 1, 1],
                     vertical_alignment: nil, horizontal_alignment: nil,
                     # TOP,MIDDLE,BOTTOM  LEFT,CENTER,RIGHT
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
    { user_entered_value:  S::ExtendedValue.new("#{value_type}_value": value),
      user_entered_format: S::CellFormat.new(
        text_format: S::TextFormat.new(font_size: font_size, bold: bold, foreground_color: color(*foreground_color)),
        background_color: color(*background_color),
        **align) }
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

  def add_banding!(sheet, sheet_id, gid, row_index, column_index, horizontal_size, first_color, second_color, banded_range_id: 0)
    range = S::GridRange.new(sheet_id: gid, start_row_index: row_index, start_column_index: column_index, end_column_index: column_index+horizontal_size)
    fcolor = color(*htmlcolor(first_color))
    scolor = color(*htmlcolor(second_color))
                                     # header as first
    bprop = S::BandingProperties.new(header_color: fcolor, first_band_color: scolor, second_band_color: fcolor)
    requests = [add_banding: S::AddBandingRequest.new(banded_range: S::BandedRange.new(banded_range_id: banded_range_id, range: range, row_properties: bprop))]
    request!(sheet, sheet_id, requests)
  end

  def insert_video!(sheet, sheet_id, gid, row_index, column_index, video, tindex, row_idx_offset: 0,
                    title_back_colors: [htmlcolor("ffffff"), htmlcolor("000000")], title_fore_colors: [htmlcolor("ffffff"), htmlcolor("000000")],
                    row_back_colors: [htmlcolor("ffffff")])
    setlist = video[:setlist]
    length = setlist.size
    id = video[:id]


    # insert and merge cell for video title
    insert!(sheet, sheet_id, gid, row_index, length)
    merge!(sheet, sheet_id, gid, row_index, column_index, length, 1)

    # video title
    url = %Q{=HYPERLINK("https://www.youtube.com/watch?v=#{id}","#{video[:title]}")}
    cells = cellsmat2cells([[
      formatted_cell(url, foreground_color: title_fore_colors[tindex%title_fore_colors.size], background_color: title_back_colors[tindex%title_back_colors.size],
                          horizontal_alignment: "CENTER", vertical_alignment: "MIDDLE",
                          wrap_strategy: "WRAP", font_size: 11, bold: true) ]*2])
    update_cells!(sheet, sheet_id, gid, row_index, column_index, cells)

    # setlist
    cells = cellsmat2cells(setlist.each_with_index.map{|el, i|
      i+= row_idx_offset

      timesec = timestamp2int(el[:time])
      name, artist = el[:body][:song_name].to_s, el[:body][:artist].to_s
      url = %Q{=HYPERLINK("https://www.youtube.com/watch?v=#{id}&t=#{timesec}","#{name}")}

      namecell = formatted_cell(url, foreground_color: [0,0,0], background_color: row_back_colors[i%row_back_colors.size],
                                wrap_strategy: "CLIP", font_size: 11, bold: true)
      artistcell = formatted_cell(artist, foreground_color: [0,0,0], background_color: row_back_colors[i%row_back_colors.size],
                                  wrap_strategy: "CLIP", font_size: 11, bold: true)
      [namecell, artistcell]
    })
    update_cells!(sheet, sheet_id, gid, row_index, column_index+1, cells)
  end

  def timestamp2int(time)
    time.split(?:).reverse.each_with_index.map{|el, i| el.to_i * 60**i}.sum
  end

  def htmlcolor(code, alpha=1)
    [*code.sub(?#, "").each_char.each_slice(2).map{|c| (c.join.to_i(16)/255.0).round(2) }, alpha]
  end

end
