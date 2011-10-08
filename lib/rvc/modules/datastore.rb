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

opts :download_vm_path do
  summary "Download a file from a datastore, specifying it with [datastoreName] /path_to_file/file.name"
  arg :object, "Some rvc object to identify connection", :lookup => RbVmomi::BasicTypes::Base
  arg :remote_path, "Filename to download"
  arg :local_path, "Filename on the local machine"
end

def download_vm_path object, remote_path, local_path
  ds_name, path = parse_file_url remote_path
  _download object, ds_name, path do |res|
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
  end 
end

opts :download do
  summary "Download a file from a datastore"
  arg :datastore_path, "Filename on the datastore", :lookup => VIM::Datastore::FakeDatastoreFile
  arg :local_path, "Filename on the local machine"
end

def download file, local_path
  download_vm_path file.datastore, format_url(file), local_path
end

opts :upload do
  summary "Upload a file to a datastore"
  arg :local_path, "Filename on the local machine"
  arg :datastore_path, "Filename on the datastore", :lookup_parent => VIM::Datastore::FakeDatastoreFolder
end

def upload local_path, dest
  vmFolder, name = *dest
  path = "#{format_url(vmFolder)}/#{name}"
  upload_vm_path local_path, vmFolder.datastore, path
end

opts :upload_vm_path do
  summary "Upload a file from a datastore, specifying it with [datastoreName] /path_to_file/file.name"
  arg :local_path, "Filename on the local machine"
  arg :object, "Some rvc object to identify connection", :lookup => RbVmomi::BasicTypes::Base
  arg :remote_path, "Filename on remote machine"
end

def upload_vm_path local_path, object, remote_path
  err "local file does not exist" unless File.exists? local_path

  ds_name, path = parse_file_url remote_path

  File.open(local_path, 'rb') do |io|
    stream = ProgressStream.new(io, io.stat.size) do |count, len|
      $stdout.write "\e[0G\e[Kuploading #{count}/#{len} bytes (#{(count*100)/len}%)"
      $stdout.flush
    end
    _upload object, stream, io.stat.size, ds_name, path
  end
end

opts :copy do
  summary "Copy file (can be between two different hosts)"
  arg :src_path, "Source filename on the datastore", :lookup => VIM::Datastore::FakeDatastoreFile
  arg :dest_path, "Destination filename on the datastore", :lookup_parent => VIM::Datastore::FakeDatastoreFolder
end

def copy src_path, dest_path
  vmFolder, name = *dest_path
  path = "#{format_url(vmFolder)}/#{name}"
  copy_vm_path src_path.datastore, format_url(src_path), vmFolder.datastore, path
end

opts :copy_vm_path do
  summary "Copy file (can be between two different hosts), specifying it with [datastoreName] /path_to_file/file.name"
  arg :src_object, "Some rvc object to identify source connection", :lookup => RbVmomi::BasicTypes::Base
  arg :src_path, "Source filename"
  arg :dest_object, "Some rvc object to identify destination connection", :lookup => RbVmomi::BasicTypes::Base
  arg :dest_path, "Source filename"
end

def copy_vm_path src_object, from_file, dest_object, dest_file
  from_ds_name, from_path = parse_file_url from_file
  dest_ds_name, dest_path = parse_file_url dest_file

  r, w = IO.pipe
  sender = fork do
    w.close
    
    dest_object._connection.restart_http
    
    len = r.read(20).to_i
    
    stream = ProgressStream.new(r, len) do |count, len|
      $stdout.write "\e[0G\e[Kcopying #{count}/#{len} bytes (#{(count*100)/len}%)"
      $stdout.flush
    end
    
    _upload dest_object, stream, len, dest_ds_name, dest_path
    r.close
  end
  r.close
  
  _download src_object, from_ds_name, from_path do |res|
    len = res.content_length
    w.write sprintf("%20i", len)
    res.read_body do |segment|
      w.write segment
    end
  end
  
  w.close
  
  Process.waitpid(sender)
  status = $?
  [src_object._connection, dest_object._connection].uniq.map{|conn| conn.restart_http}
  err "wrong return code for upload sub process #{status.exitstatus}" if status.exitstatus != 0
  true
end

class ProgressStream
  attr_reader :io

  def initialize io, len, &b
    @io = io
    @len = len
    @count = 0
    @cb = b
    @last = -1
  end

  def read n
    io.read(n).tap do |c|
      @count += c.length if c
      new_last = (@count * 200 / @len).floor
      @cb.call @count, @len if (new_last != @last) || (@count == @len)
      @last = new_last
    end
  end
end


opts :mkdir do
  summary "Create a directory on a datastore"
  arg :path, "Directory to create on the datastore", :lookup_parent => VIM::Datastore::FakeDatastoreFolder
end

def mkdir path
  vmFolder, name = *path
  mkdir_vm_path vmFolder.datastore, "#{format_url(vmFolder)}/#{name}"
end

opts :mkdir_vm_path do
  summary "Create a directory on a datastore, specifying it with [datastoreName] /path_to_file/file.name"
  arg :object, "Some rvc object to identify destination connection", :lookup => RbVmomi::BasicTypes::Base
  arg :path, "Path to create"
end

def mkdir_vm_path object, path
  object._connection.serviceContent.fileManager.MakeDirectory :name => path,
                                                              :datacenter => find_dc(object),
                                                              :createParentDirectories => false
  true
end

opts :delete do
  summary "Delete a directory or a file on a datastore"
  arg :path, "Directory to delete on the datastore"
end

def delete path
  f = lookup_single(path)
  err "datastore file or directory does not exist" unless (f.is_a? RbVmomi::VIM::Datastore::FakeDatastoreFolder) || (f.is_a? RbVmomi::VIM::Datastore::FakeDatastoreFile)
  delete_vm_path f.datastore, format_url(f)
end

opts :delete_vm_path do
  summary "Delete a directory or a file on a datastore, specifying it with [datastoreName] /path_to_file/file.name"
  arg :object, "Some rvc object to identify destination connection", :lookup => RbVmomi::BasicTypes::Base
  arg :path, "Path to delete"
end

def delete_vm_path object, path
  task = object._connection.serviceContent.fileManager.DeleteDatastoreFile_Task :name => path,
                                                                                :datacenter => find_dc(object)
  progress [task]
end


opts :edit do
  summary "Edit a file"
  arg "file", nil, :lookup => VIM::Datastore::FakeDatastoreFile
end

def edit file
  edit_vm_path file.datastore, format_url(file)
end

rvc_alias :edit, :vi

opts :edit_vm_path do
  summary "Edit a file, specifying it with [datastoreName] /path_to_file/file.name"
  arg :object, "Some rvc object to identify connection", :lookup => RbVmomi::BasicTypes::Base
  arg :file, nil
end

def edit_vm_path object, file
  editor = ENV['VISUAL'] || ENV['EDITOR'] || 'vi'
  download_in_tmp_file object, file do |filename|
    pre_stat = File.stat filename
    system("#{editor} #{filename}")
    post_stat = File.stat filename
    if pre_stat != post_stat
      upload_vm_path filename, object, file
    end
  end
end

opts :cat do
  summary "Display a file"
  arg "file", nil, :lookup => VIM::Datastore::FakeDatastoreFile
end

def cat file
  cat_vm_path file.datastore, format_url(file)
end

opts :cat_vm_path do
  summary "Display a file, specifying it with [datastoreName] /path_to_file/file.name"
  arg :object, "Some rvc object to identify connection", :lookup => RbVmomi::BasicTypes::Base
  arg :file, nil
end

def cat_vm_path object, file
  download_in_tmp_file object, file do |filename|
    puts File.read(filename)
  end
end

def download_in_tmp_file object, file
  filename = File.join(Dir.tmpdir, "rvc.#{Time.now.to_i}.#{rand(65536)}")
  download_vm_path object, file, filename
  begin
    yield filename
  ensure
    File.unlink filename
  end
end

def http_path dc_name, ds_name, path
  "/folder/#{URI.escape path}?dcPath=#{URI.escape dc_name}&dsName=#{URI.escape ds_name}"
end

def parse_file_url url
  if url =~ /\[(.*)\] (.*)/
     return $1, $2
   else
     err "Unable to parse remote path #{remote_path}"
   end
end

def find_dc object
  dc = object
  while !dc.is_a? RbVmomi::VIM::Datacenter
    dc = dc.parent
  end
  dc
end

def format_url file
  "[#{file.datastore.name}] #{file.path}"
end

def _download object, ds_name, path
  dc = find_dc object
  path = http_path dc.name, ds_name, path
  request = Net::HTTP::Get.new path
  object._connection.http_request(request) do |res|
    case res
    when Net::HTTPOK
      yield res
    else
      err "download failed: #{res.message}"
    end
  end
end

def _upload object, stream, len, ds_name, path
  dc = find_dc object
  headers = {
    'content-length' => len.to_s,
    'Content-Type' => 'application/octet-stream'
  }
  path = http_path dc.name, ds_name, path
  request = Net::HTTP::Put.new path, headers
  request.body_stream = stream
  object._connection.http_request(request) do |res|
    $stdout.puts
    case res
    when Net::HTTPSuccess
    else
      err "upload failed: #{res.message}"
    end
  end
end
