#!/usr/bin/env ruby

require 'csv'

# https://docs.google.com/spreadsheets/d/1O4DiUoZiq8qaUNnvCzlg8DjALN7KkGbbJ3o6yVCOFoA/edit#gid=1246821289
# https://docs.google.com/spreadsheets/d/1hZFm780z4k9wowHnWo_-o6rVkWpgUhbg_EKw1ukFHtc/edit#gid=0
# https://docs.google.com/spreadsheets/d/1G9Xt1wJGNmrSxAUjAPUNOSjYmgaFq0f1XBmsdKkQUX8/edit#gid=0

# ARGV
#  intput_csv
#  output_csv
#  drop num
#  col_index

input_csv_name = ARGV.first

uniq_csv = CSV.read(input_csv_name)
puts "#{uniq_csv.size} lines input"

col_idx = ARGV[3]&.to_i || 1

uniq_csv = uniq_csv
  .drop(ARGV[2]&.to_i || 1)#.take(3)
  .map{|row| row[col_idx..col_idx+1] }
  .reject{|el| el.first.to_s.empty? or el[1].to_s.empty? }
  .map{|row| row.map{|e| e.strip} }
  .uniq{|row| row.join.downcase }
  .sort{|l, r| l.first <=> r.first}
  .to_a
puts "#{uniq_csv.size} lines output"

CSV.open(ARGV[1], "wb") do |csv|
  uniq_csv.each{|row| csv << row }
end
