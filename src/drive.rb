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
