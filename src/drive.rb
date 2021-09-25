require 'csv'

require 'google/apis/drive_v3'

require_relative "params"

module DriveUtil
  extend self
  include Params::Drive

  D = Google::Apis::DriveV3
  PY = Params::YouTube
  CE = Google::Apis::ClientError

  def get_drive(json_path)
		drive = Google::Apis::DriveV3::DriveService.new
		authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
			json_key_io: File.open(json_path),
			scope: %w(https://www.googleapis.com/auth/drive
                https://www.googleapis.com/auth/drive.file
                https://www.googleapis.com/auth/drive.appdata
                https://www.googleapis.com/auth/drive.photos.readonly))
    authorizer.fetch_access_token!
    drive.authorization = authorizer

    return drive
  end

  def run(&block)
    block.call
  rescue Google::Apis::ClientError => e
    puts "ERROR", (JSON.parse(e.body)["error"] rescue e.body)
    return e
  end

  def init_sheet(drive, yid, templ_sheet_id, view_dir_id)
    p PY::DATA_DIR / PY::CHANNELS_CSV
    begin
      channels_csv = CSV.read(PY::DATA_DIR / PY::CHANNELS_CSV)
    rescue
      puts "Init project first"
      return
    end

    if (row = channels_csv.select{|row| row[PY::CHANNELS_CSV_FORMAT[:id]] == yid}.first).nil? then
      puts "Not found #{yid}"
      return
    end

    name, yid, sheet_id = row
    puts "Found #{name} (#{yid})"

    if not sheet_id.nil? then
      puts "Sheet #{sheet_id} already exists"
      return
    end

    copied = copy_file(drive, templ_sheet_id, name, view_dir_id)
    sheet_id = copied.id

    f = make_shared(drive, sheet_id)
    sheet_url = f.web_view_link

    puts "Sheet ID is #{sheet_id}, url is #{sheet_url}"
    row << sheet_id
    row << sheet_url

    CSV.open(PY::DATA_DIR / PY::CHANNELS_CSV, "wb") do |csv|
      channels_csv.uniq.each{|r| csv << r }
    end
  end

  def copy_file(drive, file_id, dest_name, dest_dirs)
    dest_dirs = [dest_dirs] if dest_dirs.is_a? String

    file_obj = D::File.new(name: dest_name, parents: dest_dirs)
    drive.copy_file(file_id, file_obj)
  end

  def make_shared(drive, file_id)
    drive.create_permission(file_id, D::Permission.new(role: 'reader', type: 'anyone'))
    drive.get_file(file_id, fields: 'webViewLink')
  end
end
