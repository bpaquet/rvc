# Copyright (c) 2011 VMware, Inc.  All Rights Reserved.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

opts :download do
  summary "Download a file from a datastore"
  arg 'datastore-path', "Filename on the datastore", :lookup => VIM::Datastore::FakeDatastoreFile
  arg 'local-path', "Filename on the local machine"
end

def download file, local_path
  main_http = file.datastore._connection.http
  http = Net::HTTP.new(main_http.address, main_http.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  #http.set_debug_output $stderr
  http.start
  err "certificate mismatch" unless main_http.peer_cert.to_der == http.peer_cert.to_der

  headers = { 'cookie' => file.datastore._connection.cookie }
  path = http_path file.datastore.send(:datacenter).name, file.datastore.name, file.path
  http.request_get(path, headers) do |res|
    case res
    when Net::HTTPOK
      len = res.content_length
      count = 0
      File.open(local_path, 'wb') do |io|
        res.read_body do |segment|
          count += segment.length
          io.write segment
          $stdout.write "\e[0G\e[Kdownloading #{count}/#{len} bytes (#{(count*100)/len}%)"
          $stdout.flush
        end
      end
      $stdout.puts
    else
      err "download failed: #{res.message}"
    end
  end
end


opts :upload do
  summary "Upload a file to a datastore"
  arg 'local-path', "Filename on the local machine"
  arg 'datastore-path', "Filename on the datastore", :lookup_parent => VIM::Datastore::FakeDatastoreFolder
end

def upload local_path, dest
  dir, datastore_filename = *dest
  err "local file does not exist" unless File.exists? local_path
  real_datastore_path = "#{dir.path}/#{datastore_filename}"

  main_http = dir.datastore._connection.http
  http = Net::HTTP.new(main_http.address, main_http.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  #http.set_debug_output $stderr
  http.start
  err "certificate mismatch" unless main_http.peer_cert.to_der == http.peer_cert.to_der

  File.open(local_path, 'rb') do |io|
    stream = ProgressStream.new(io, io.stat.size) do |s|
      $stdout.write "\e[0G\e[Kuploading #{s.count}/#{s.len} bytes (#{(s.count*100)/s.len}%)"
      $stdout.flush
    end

    headers = {
      'cookie' => dir.datastore._connection.cookie,
      'content-length' => io.stat.size.to_s,
      'Content-Type' => 'application/octet-stream',
    }
    path = http_path dir.datastore.send(:datacenter).name, dir.datastore.name, real_datastore_path
    request = Net::HTTP::Put.new path, headers
    request.body_stream = stream
    res = http.request(request)
    $stdout.puts
    case res
    when Net::HTTPSuccess
    else
      err "upload failed: #{res.message}"
    end
  end
end

class ProgressStream
  attr_reader :io, :len, :count

  def initialize io, len, &b
    @io = io
    @len = len
    @count = 0
    @cb = b
  end

  def read n
    io.read(n).tap do |c|
      @count += c.length if c
      @cb[self]
    end
  end
end


opts :mkdir do
  summary "Create a directory on a datastore"
  arg 'path', "Directory to create on the datastore"
end

def mkdir datastore_path
  datastore_dir_path = File.dirname datastore_path
  dir = lookup_single(datastore_dir_path)
  err "datastore directory does not exist" unless dir.is_a? RbVmomi::VIM::Datastore::FakeDatastoreFolder
  ds = dir.datastore
  dc = ds.path.find { |o,x| o.is_a? RbVmomi::VIM::Datacenter }[0]
  name = "#{dir.datastore_path}/#{File.basename(datastore_path)}"
  dc._connection.serviceContent.fileManager.MakeDirectory :name => name,
                                                          :datacenter => dc,
                                                          :createParentDirectories => false
end


opts :delete do
  summary "Delete a directory or a file on a datastore"
  arg 'path', "Directory to delete on the datastore"
end

def delete datastore_path
  dir = lookup_single(datastore_path)
  err "datastore file or directory does not exist" unless (dir.is_a? RbVmomi::VIM::Datastore::FakeDatastoreFolder) || (dir.is_a? RbVmomi::VIM::Datastore::FakeDatastoreFile)
  ds = dir.datastore
  dc = ds.path.find { |o,x| o.is_a? RbVmomi::VIM::Datacenter }[0]
  name = "#{dir.datastore_path}"
  task = dc._connection.serviceContent.fileManager.DeleteDatastoreFile_Task :name => name,
                                                                            :datacenter => dc
  progress [task]
end


opts :edit do
  summary "Edit a file"
  arg "file", nil, :lookup => VIM::Datastore::FakeDatastoreFile
end

rvc_alias :edit, :vi

def edit file
  editor = ENV['VISUAL'] || ENV['EDITOR'] || 'vi'
  filename = File.join(Dir.tmpdir, "rvc.#{Time.now.to_i}.#{rand(65536)}")
  download file, filename
  begin
    pre_stat = File.stat filename
    system("#{editor} #{filename}")
    post_stat = File.stat filename
    if pre_stat != post_stat
      upload filename, [file.parent, File.basename(file.path)]
    end
  ensure
    File.unlink filename
  end
end


def http_path dc_name, ds_name, path
  "/folder/#{URI.escape path}?dcPath=#{URI.escape dc_name}&dsName=#{URI.escape ds_name}"
end
