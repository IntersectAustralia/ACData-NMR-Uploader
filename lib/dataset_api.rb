class DatasetAPI
  require 'json'
  require 'uri'
  require 'net/http'

  BOUNDARY        = "IntersectACDataDatasetAPI"
  COOKIE_NAME     = '_acdata_session'
  SIGNIN_URL      = '/users/sign_in.json'
  DATASET_URL     = '/api/datasets'
  INSTRUMENTS_URL = '/api/instruments'
  SAMPLES_URL     = '/api/samples'
  PROJECTS_URL    = '/api/projects'

  def initialize(base_url=nil)
    @base_url = base_url || 'https://www.researchdata.unsw.edu.au'
  end

  def login(username, password)
    signin_url = URI.parse(@base_url + SIGNIN_URL)
    http = Net::HTTP::new(signin_url.host, signin_url.port)
    http.use_ssl = true if signin_url.scheme == 'https'
    req = Net::HTTP::Post.new(
        signin_url.path,
        initheader = {
          'Content-type' => 'application/json',
          'Accept' => 'application/json'
        }
    )
    req.body = {'user' => {'login' => username, 'password' => password}}.to_json
    res = http.request(req)
    unless res.is_a?(Net::HTTPCreated)
      raise "Unexpected response to login: #{res.code} #{res.message}"
    end
    get_cookie(res)
  end

  def instruments(session)
    do_action(session, INSTRUMENTS_URL)
  end

  def samples(session)
    do_action(session, SAMPLES_URL)
  end

  def projects(session)
    do_action(session, PROJECTS_URL)
  end

  def create_sample(session, opts)
    url = URI.parse("#{@base_url + SAMPLES_URL}")
    http = Net::HTTP::new(url.host, url.port)

    req = Net::HTTP::Post.new(
        url.path,
        initheader = {
          'Content-type' => 'application/json',
          'Accept' => 'application/json',
          'Cookie' => cookie_string(session)
        }
    )
 
    req.body = {
      'project_id' => opts[:project_id],
      'experiment_id' => opts[:experiment_id],
      'sample' => {
        'name' => opts[:name],
        'description' => opts[:description]
      }
    }.to_json
    resp = http.request(req)
    unless resp.is_a?(Net::HTTPCreated)
      raise "Unexpected response to create_sample: #{resp.code} #{resp.message}"
    end
    parse_body(resp.body)
  end

  def create_dataset(session, name, instrument_id, sample_id, files, metadata={})

    url = URI.parse("#{@base_url + DATASET_URL}")
    http = Net::HTTP::new(url.host, url.port)

    req = Net::HTTP::Post.new(
        url.path,
        initheader = {
          'Accept' => 'application/json',
          'Cookie' => cookie_string(session)
        }
    )
    files_struct, file_map = self.class.build_files_structure(files)
    dataset_json = {
      :name => name,
      :sample_id => sample_id,
      :instrument_id => instrument_id,
      :files => files_struct,
      :metadata => metadata
    }.to_json

    req.body = post_body(dataset_json, file_map).join

    req["Content-Type"] = "multipart/form-data, boundary=#{BOUNDARY}"
    resp = http.request(req)
    unless resp.is_a?(Net::HTTPCreated)
      raise "Unexpected response to create_dataset: #{resp.code} #{resp.message}"
    end
    parse_body(resp.body)
  end

  def self.build_files_structure(files)
    files_struct = []
    file_map = {}
    sequence = 1
    files.each do |f|
      if File.directory?(f)
        root_path = File.join(File.dirname(f), '')
        folder = File.basename(f)
        sequence = self.add_folder(root_path, folder, files_struct, file_map, sequence)
      elsif File.file?(f)
        files_struct << self.add_file(File.basename(f), sequence)
        file_map["file_#{sequence}"] = f
        sequence += 1
      else
        raise "Expecting list of files to build_files_structure"
      end
    end
    [files_struct, file_map]
  end

  private

  def get_cookie(resp)
    sess = nil
    resp.to_hash['set-cookie'].each do |cookie|
      next unless cookie.match(COOKIE_NAME)
      (key, value) = cookie.split('; ')[0].split('=')
      sess = value
    end
    sess
  end

  def cookie_string(session)
    "#{COOKIE_NAME}=#{session}" if session
  end

  def parse_body(body)
    if body
      parsed_body = body.strip
    
      if parsed_body.size > 0
        JSON.parse(parsed_body)
      end
    end
  end

  def do_action(session, action_url)
    url = URI.parse(@base_url + action_url)
    http = Net::HTTP.start(url.host, url.port, :use_ssl => url.scheme == 'https')
    initheader = {
      'Content-type' => 'application/json',
      'Accept'       => 'application/json'
    }
    cookie = cookie_string(session)
    if cookie
      initheader['Cookie'] = cookie
    end
    resp = http.request_get(url.path, initheader)

    unless resp.is_a?(Net::HTTPSuccess)
      raise "Unexpected response to #{action_url}: #{resp.code} #{resp.message}"
    end

    parse_body(resp.body)
  end

  def post_body(dataset_json, file_map)
    body = []
    body << "--#{BOUNDARY}\r\n"
    body << "Content-Disposition: form-data; name=\"dataset\"\r\n"
    body << "Content-Type: application/json; charset=utf-8\r\n"
    body << "Content-Transfer-Encoding: 8bit\r\n"
    body << "\r\n"
    body << "#{dataset_json}\r\n"
    file_map.each do |id,file_path|
      filename = File.basename(file_path)
      body << "--#{BOUNDARY}\r\n"
      body << "Content-Disposition: form-data; name=\"#{id}\"; filename=\"#{filename}\"\r\n"
      body << "Content-Type: application/octet-stream; charset=ISO-8859-1\r\n"
      body << "Content-Transfer-Encoding: binary\r\n"
      body << "\r\n"
      body << open(file_path, "rb") {|io| io.read }
      body << "\r\n"
    end
    body << "\r\n--#{BOUNDARY}--\r\n"
  end

  def self.add_folder(root_path, folder, files_struct, file_map, sequence)
    container = {
      "folder_root" => folder
    }
    glob_path = File.join(root_path, folder, '**', '*')
    Dir.glob(glob_path).each do |f|
      rel_path = f.gsub(File.join(root_path, ''), '')
      if File.directory?(f)
        container["folder_#{sequence}"] = rel_path
      else
        container["file_#{sequence}"] = rel_path
        file_map["file_#{sequence}"] = f
      end
      sequence += 1
    end
    files_struct << container
    sequence
  end

  def self.add_file(path, sequence)
    { "file_#{sequence}" => path }
  end

end
