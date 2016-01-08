require 'fileutils'

module ParallelCalabash
  module DevicesHelper
    def device_for_process process_num
      connected_devices_with_model_info[process_num]
    end

    def number_of_connected_devices
      connected_devices_with_model_info.size
    end


  end

  class AdbHelper
    include ParallelCalabash::DevicesHelper

    def initialize(filter = [], form_factor_filter=:undefined)
      @filter = filter
      @form_factor_filter = form_factor_filter
    end

    def adb_devices_l
      `adb devices -l`
    end

    def adb_get_characteristics device_id
      `adb -s #{device_id} shell getprop ro.build.characteristics`.strip
    end

    def is_tablet? device_id
      characteristics = adb_get_characteristics device_id
      characteristics.include? 'tablet'
    end

    def form_factor_match device
      if @form_factor_filter.nil?
        true
      else
        is_tablet = device[2]
        looking_tablet = (@form_factor_filter == :tablet)
        is_tablet == looking_tablet
      end
    end

    def connected_devices_with_model_info
      begin
        if(@list.nil?)
          @list =
              adb_devices_l.split("\n").collect do |line|
                device = device_id_and_model(line)
                unless device.nil?
                  device.push(is_tablet?(device[0]))
                  filter_device(device)
                end
              end
          #added randomization so that it will not always use the same devices for the same tests
          @list = @list.compact.shuffle.each { |device_data| device_data << screenshot_prefix(device_data.first) }
        end
        @list
      rescue
        []
      end
    end

    def screenshot_prefix device_id
      device_id.gsub('.', '_').gsub(/:(.*)/, '').to_s + '_'
    end

    def device_id_and_model line
      if line.match(/device(?!s)/)
        [line.split(" ").first, line.scan(/model:(.*) device/).flatten.first]
      end
    end

    def filter_device device
      if form_factor_match(device)
        if @filter && !@filter.empty? && device
          device unless @filter.collect { |f| device[0].match(f) || device[1].match(f) }.compact.empty?
        else
          device
        end
      end
    end
  end

  class IosHelper
    include ParallelCalabash::DevicesHelper

    def initialize(filter = nil, default_simulator = nil, config_file = nil, instruments = nil)
      @filter = filter || []
      @default_simulator = default_simulator || {}
      config_file = config_file || "#{ENV['HOME']}/.parallel_calabash"
      if config_file.is_a? Hash
          @config = config_file
        else
          @config = File.exist?(config_file) ? eval(File.read(config_file)) : {}
      end
      @instruments = instruments || %x(instruments -s devices ; echo) # Bizarre workaround for xcode 7
    end

    def xcode7?
      !@instruments.match(' Simulator\)')
    end

    def connected_devices_with_model_info
      return @devices if @devices
      if @config[:DEVICES]
        configs = apply_filter(compute_devices)
        fail '** No devices (or users) unfiltered!' if configs.empty?
      else
        configs = apply_filter(compute_simulators)
        configs = configs.empty? ? [@default_simulator] : configs
      end
      @devices = configs
    end

    def compute_simulators
      port = (@config[:CALABASH_SERVER_PORT] || 28000).to_i
      users = @config[:USERS] || []
      init = @config[:INIT] || ''
      simulator = @config[:DEVICE_TARGET] || nil
      users.map.with_index do |u, i|
        {}.tap do |my_hash|
          my_hash[:USER] = u
          my_hash[:CALABASH_SERVER_PORT] = port + i
          my_hash[:INIT] = init
          my_hash[:DEVICE_TARGET] = simulator unless simulator.nil?
        end
      end
    end

    def compute_devices
      users = @config[:USERS] || []
      init = @config[:INIT] || ''
      devices = remove_unconnected_devices(@config[:DEVICES])
      fail 'Devices configured, but no devices attached!' if devices.empty?
      configs = devices.map.with_index do |d, i|
        if users[i]
          d[:USER] = users[i]
          d[:INIT] = init
          d
        else
          print "** No user for device #{d}"
          nil
        end
      end
      configs.compact
    end

    def apply_filter(configs)
      return configs if @filter.empty?
      filter_join = @filter.join('|')
      configs.select do |c|
        [c.keys, c.values].flatten.find { |k| k.to_s.match(filter_join) }
      end
    end

    def remove_unconnected_devices(configs)
      udids = @instruments.each_line.map { |n| n.match(/\[(.*)\]/) && $1 }.flatten.compact
      configs.find_all do |c|
        var = c[:DEVICE_TARGET]
        !udids.grep(var).empty?
      end
    end
  end
end
