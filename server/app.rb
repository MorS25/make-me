#!/usr/bin/env ruby

require 'bundler'
Bundler.require
require 'timeout'
require_relative 'lib/download'
require_relative 'lib/normalizer'

module MakeMe
  class App < Sinatra::Base
    PID_FILE  = File.join('tmp', 'make.pid')
    LOG_FILE  = File.join('tmp', 'make.log')
    FETCH_MODEL_FILE = File.join('data', 'fetch.stl')
    CURRENT_MODEL_FILE = File.join('data', 'print.stl')

    ## Config
    set :static, true
    enable :method_override

    basic_auth do
      realm 'The 3rd Dimension'
      username ENV['MAKE_ME_USERNAME'] || 'hubot'
      password ENV['MAKE_ME_PASSWORD'] || 'isalive'
    end

    helpers do
      def progress
        progress = 0
        if File.exists?(LOG_FILE)
          File.readlines(LOG_FILE).each do |line|
            matches = line.strip.scan /Sent \d+\/\d+ \[(\d+)%\]/
            matches.length > 0 && progress = matches[0][0].to_i
          end
        end
        progress
      end
    end

    get '/' do
      @current_log = File.read(LOG_FILE) if File.exists?(LOG_FILE)
      erb :index
    end

    get '/about' do
      erb :about
    end

    get '/current_model' do
      if File.exist?(CURRENT_MODEL_FILE)
        content_type "application/sla"
        send_file CURRENT_MODEL_FILE
      else
        status 404
        "not found"
      end
    end

    get '/photo' do
      imagesnap = File.join(File.dirname(__FILE__), '..', 'vendor', 'imagesnap', 'imagesnap')
      out_name = 'snap_' + Time.now.to_i.to_s + ".jpg"
      out_dir = File.join(File.dirname(__FILE__), "public")

      # Ask for the all the cameras we have
      # the first line is a header.
      cameras = IO.popen([imagesnap, "-l"]) do |cameras|
        cameras.readlines
      end[1..-1]

      # Pick one safely and use it
      camera = cameras[params[:camera].to_i % cameras.length].strip
      puts "Picked camera: [#{camera}]"

      Process.wait Process.spawn(*[imagesnap, '-d', camera, File.join(out_dir, out_name)])

      redirect out_name
    end

    ## Routes/Authed
    post '/print' do
      require_basic_auth
      if locked?
        halt 423, lock_data
      else
        lock!
      end

      args = Yajl::Parser.new(:symbolize_keys => true).parse(request.body.read) || {}

      stl_urls      = [*args[:url]]
      count         = args[:count]
      scale         = args[:scale]
      grue_conf     = (args[:config]  || 'default')
      slice_quality = (args[:quality] || 'medium')
      density       = (args[:density] || 0.05).to_f

      normalizer_args = {}
      normalizer_args[:count] = count if count
      normalizer_args[:scale] = scale if scale

      # Fetch all of the inputs to temp files
      inputs = MakeMe::Download.new(stl_urls, FETCH_MODEL_FILE).fetch

      output = CURRENT_MODEL_FILE
      normalizer = MakeMe::Normalizer.new(inputs, output, normalizer_args)
      unless normalizer.normalize!
        halt 409, "Normalizing model failed"
      end

      # Print the normalized STL
      make_params = [ "GRUE_CONFIG=#{grue_conf}",
                      "QUALITY=#{slice_quality}",
                      "DENSITY=#{density}"]

      make_stl    = [ "make", *make_params,
                      "#{File.dirname(output)}/#{File.basename(output, '.stl')};",
                      "rm #{PID_FILE}"].join(" ")

      # Kick off the print, if it runs for >5 seconds, it's unlikely it failed
      # during slicing
      begin
        pid = Process.spawn(make_stl, :err => :out, :out => [LOG_FILE, "a"])
        File.open(PID_FILE, 'w') { |f| f.write pid }
        Timeout::timeout(5) do
          Process.wait pid
          status 500
          "Process died within 5 seconds with exit status #{$?.exitstatus}"
        end
      rescue Timeout::Error
        status 200
        "Looks like it's printing correctly"
      end
    end

    get '/log' do
      content_type :text
      File.read(LOG_FILE) if File.exists?(LOG_FILE)
    end
  end
end

require_relative 'app/lock'
