require 'acdata-dataset-api'
require 'optparse'
require 'ostruct'
require 'highline/import'
require 'json'
require 'find'

class NMRUploader

  DEFAULT_URL = 'https://researchdata.unsw.edu.au'

  def self.create_datasets(opts)
    api = ACDataDatasetAPI.new(opts.url)
    opts.sample_directories.keys.each do |sample_dir|
      sample_name = File.basename(sample_dir)
      begin
        params = {
          :project_id => opts.project_id,
          :name => sample_name
        }
        if !(opts.experiment_id.nil? or opts.experiment_id.empty?)
          params[:experiment_id] = opts.experiment_id
        end
        sample = api.create_sample(opts.session_id, params)

        opts.sample_directories[sample_dir].each do |dataset_dir|
          title = self.extract_title(dataset_dir)
          jcamp_file = self.jcamp_exists(dataset_dir)
          upload_files = (jcamp_file << dataset_dir).flatten
          puts "Creating dataset name: #{title} (under sample: #{sample_name})"
          api.create_dataset(opts.session_id, title, opts.instrument_id, sample['id'], upload_files)
        end
        puts
      rescue Exception => e
        $stderr.puts "Problem importing: #{e.message}"
        $stderr.puts "Will skip this one and continue"
      end
    end

  end

  def self.jcamp_exists(nmr_dir)
    file_path = File.join(nmr_dir, 'pdata','1','**/*.dx')
    Dir.glob(file_path)
    
  end
  
  def self.extract_title(nmr_dir)
    title_file_path = File.join(nmr_dir, 'pdata', '1', 'title')
    title = "Untitled"
    if File.exists?(title_file_path)
      file = File.open(title_file_path, 'rb')
      text = file.read
      text.gsub!(/(\r|\n)+/, ' ')
      text.strip!
      title = text unless text.empty?
    end

    title += " - #{nmr_dir[/\w+$/]}"
    title
    
  end

  def self.get_sample_directories(base_dir)
    dir_map = {}
    Dir.glob(File.join(base_dir, '*')).each do |dataset_dir|
      pdata = File.join(dataset_dir, 'pdata')
      next unless File.exists?(pdata)
      if dir_map.has_key?(base_dir)
        dir_map[base_dir] << dataset_dir
      else
        dir_map[base_dir] = [ dataset_dir ]
      end
    end
    dir_map
  end

  def self.instrument_list(instrument_map)
    i_classes = instrument_map['instruments']
    id_name = {}
    i_classes.keys.each do |ic|
      i_classes[ic].each do |instrument|
        id_name[instrument['id']] = "(#{ic}) #{instrument['name']}"
      end
    end
    id_name
  end

  def self.project_list(project_map)
    id_name = {}
    project_map['projects'].each do |project|
      id_name[project['id']] = project['name']
    end
    id_name
  end

  def self.parse_options(options=nil)
    options ||= OpenStruct.new
    options.src_dir = nil
    options.instrument_id = nil
    options.project_id = nil
    options.experiment_id = nil

    OptionParser.new do |opts|
      opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

      opts.on("-i", "--instrument_id=ID") do |instrument_id|
        options.instrument_id = instrument_id
      end

      opts.on("-p", "--project_id=ID") do |project_id|
        options.project_id = project_id
      end

      opts.on("-u", "--username=zID") do |user_name|
        options.user_name = user_name
      end

      opts.on("-d", "--directory=nmr_dataset_dir", "Parent directory containing the NMR data directories. E.g. Gyro/data/abc/nmr/YYYYMMDD-abc") do |dir|
        raise "#{dir} does not exist" unless File.exists?(dir)
        options.src_dir = dir
      end

      opts.on("--url=base_server_url", "URL of ACData instance") do |url|
        options.url = url
      end

      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
      end
    end.parse!

    while options.src_dir.nil? or !File.directory?(options.src_dir)
      puts
      puts "Enter the directory containing the NMR data directories."
      puts "E.g. Gyro/data/abc/nmr/YYMMDD-aaa"
      puts
      options.src_dir = prompt_for("NMR directory")
    end

    options.sample_directories = get_sample_directories(options.src_dir)
    if options.sample_directories.empty?
      $stderr.puts("No suitable NMR directories found")
      exit
    else
      puts
      puts "Samples/datasets to be imported: "
      puts options.sample_directories.values.join("\n")
      puts
      continue = prompt_for('Proceed with import? (y/N)')
      exit unless continue =~ /^y(es)?$/i
    end

    options.url ||= DEFAULT_URL
    api = ACDataDatasetAPI.new(options.url)
    if options.session_id.nil?
      if options.user_name.nil?
        puts
        options.user_name = prompt_for('zID')
      end

      begin
        options.password = prompt_for('zPass', {:hidden => true})
        options.session_id = api.login(options.user_name, options.password)
      ensure
        options.password = nil
      end
    end
    
    instrument_map = api.instruments(options.session_id)
    list = instrument_list(instrument_map)
    while options.instrument_id.nil? or !list.has_key?(options.instrument_id.to_i)
      puts
      puts "Enter the ID of the instrument your datasets were created from:"
      puts
      list.sort.map{|k,v| puts "%4s : #{v}" % k}
      options.instrument_id = prompt_for('Instrument ID')
    end

    project_map = api.projects(options.session_id)
    project_list = {}
    (project_map['owner'] + project_map['collaborator']).map{|p| project_list[p['id']] = p }
    while options.project_id.nil? or !project_list.has_key?(options.project_id.to_i)
      puts
      puts "Enter the ID of the project to add your samples/datasets to:"
      puts
      project_list.keys.sort.map{|id| puts "%5s : #{project_list[id]['name']}" % id}
      options.project_id = prompt_for('Project ID')
    end

    project = project_list[options.project_id.to_i]
    if !project['experiments'].empty?
      valid = false
      begin
        puts
        puts "Enter the ID of the experiment to add your samples/datasets to:"
        puts
        project['experiments'].map{|e|
          puts "%5s : #{e['name']}" % e['id']
        }
        options.experiment_id = prompt_for('Experiment ID [Enter to skip]')
        options.experiment_id = nil if options.experiment_id == ""
        valid = options.experiment_id.nil? ||
                has_experiment?(project, options.experiment_id.to_i)
      end until valid
      
    end

    options
  end

  def self.prompt_for(key, opts={})
    ask("#{key}: ") {|q| q.echo = opts[:hidden] != true}
  end

  private
  def self.has_experiment?(project, experiment_id)
    !project['experiments'].select{|e| e['id'] == experiment_id}.empty?
  end
end

