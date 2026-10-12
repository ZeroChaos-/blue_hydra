# Preloaded into a child `ruby -r <this> bin/blue_hydra ...` by spec/no_db_spec.rb.
# Never require it from the spec process itself: it patches Process, Dir and
# File globally.
#
# bin/blue_hydra runs for real - its OptionParser, its require order and lib's
# database selection - with only the root/hardware touch points stubbed. When
# bin reaches Runner.new (every option has been applied by then) the harness
# writes a JSON report to $BH_HARNESS_REPORT, saves one probe device so a second
# start in the same cwd shows whether it inherits it, and exits without
# starting btmon or scanning.
#
# With BH_HARNESS_MAC_READ_FAILS=1 the hci MAC read returns nothing, so lib sends
# its FATAL event and exits 1 while it is being required. Runner.new is never
# reached then, and the at_exit at the bottom writes the report instead.
require 'json'

BH_HARNESS_REPORT         = ENV.fetch("BH_HARNESS_REPORT")
BH_HARNESS_MAC_READ_FAILS = ENV["BH_HARNESS_MAC_READ_FAILS"] == "1"
BH_HARNESS_EVENTS         = []

Process.singleton_class.prepend(Module.new { def uid; 0; end })

# Keep every path lib derives from these directories local to the checkout and
# cwd, whatever exists on the host.
Dir.singleton_class.prepend(Module.new do
  def exist?(path)
    return false if ["/etc/blue_hydra", "/etc/blue_hydra/", "/var/log/blue_hydra"].include?(path.to_s)
    super
  end
end)

File.singleton_class.prepend(Module.new do
  def write(path, *args, **kw)
    path = File.join(Dir.pwd, "blue_hydra.pid") if path.to_s == "/var/run/blue_hydra.pid"
    super(path, *args, **kw)
  end
end)

def bh_harness_db_files
  Dir.glob(File.join(Dir.pwd, "*.db*")).sort.map { |f| { "path" => f, "size" => File.size(f) } }
end

# database files this process holds open, as the kernel sees them
def bh_harness_open_db_files
  Dir.glob("/proc/self/fd/*").filter_map do |fd|
    begin
      target = File.readlink(fd)
    rescue SystemCallError
      next
    end
    target if File.basename(target).include?(".db")
  end.sort
end

bh_harness_patched = {}
TracePoint.new(:end) do |tp|
  name = (tp.self.name rescue nil)
  next if name.nil? || bh_harness_patched[name]

  case name
  # lib reads the adapter address at require time, and dm-core is already
  # loaded by then, so this is the earliest point both can be patched.
  when "BlueHydra::Mgmt"
    bh_harness_patched[name] = true
    BlueHydra::Mgmt.prepend(Module.new do
      def read_address; BH_HARNESS_MAC_READ_FAILS ? nil : "00:11:22:33:44:55"; end
      def close; end
    end)
    BlueHydra.singleton_class.prepend(Module.new do
      def send_event(key, hash)
        loc = caller_locations(1, 1).first
        BH_HARNESS_EVENTS << {
          "event"  => "BlueHydra.send_event",
          "key"    => key,
          "hash"   => hash,
          "flags"  => {
            "pulse"                => BlueHydra.pulse,
            "stream_builder"       => BlueHydra.stream_builder,
            "stream_builder_debug" => BlueHydra.stream_builder_debug
          },
          "caller" => [loc.path, loc.label]
        }
        super
      end
    end)
    # The services are recorded, not called, so the Docker build's real Stream
    # Builder publishes nothing.
    BlueHydra::Pulse.singleton_class.prepend(Module.new do
      def send_event(key, hash)
        BH_HARNESS_EVENTS << { "event" => "Pulse.send_event", "key" => key, "hash" => hash }
        nil
      end
    end)
    BlueHydra::StreamBuilder.singleton_class.prepend(Module.new do
      def send_event(name, value, dimensions: [], unit: nil, namespace: nil)
        BH_HARNESS_EVENTS << {
          "event"      => "StreamBuilder.send_event",
          "name"       => name,
          "value"      => value,
          "dimensions" => dimensions
        }
        nil
      end
    end)
    DataMapper.singleton_class.prepend(Module.new do
      def setup(*args)
        BH_HARNESS_EVENTS << {
          "event"          => "DataMapper.setup",
          "args"           => args.map(&:to_s),
          "no_db_at_setup" => BlueHydra.no_db,
          "caller"         => caller_locations(1, 1).first.to_s
        }
        super
      end
    end)
  when "BlueHydra::Runner"
    bh_harness_patched[name] = true
    BlueHydra::Runner.singleton_class.prepend(Module.new do
      def new(*)
        adapter = DataMapper.repository(:default).adapter
        report = {
          "runner_reached"        => true,
          "argv_after_parse"      => ARGV,
          "events"                => BH_HARNESS_EVENTS,
          "no_db"                 => BlueHydra.no_db,
          "daemon_mode"           => BlueHydra.daemon_mode,
          "adapter_path"          => adapter.options["path"],
          "sync_version"          => BlueHydra::SYNC_VERSION,
          "device_count_at_start" => BlueHydra::Device.count,
          # runner.rb's START replay ("Marking older devices as 'offline'")
          # runs exactly when this is true.
          "replays_previous_rows" => !BlueHydra::Device.first.nil?,
          "db_files_in_cwd"       => bh_harness_db_files
        }

        # The probe save must not reach Pulse or Stream Builder.
        BlueHydra.pulse = false
        BlueHydra.stream_builder = false
        BlueHydra.stream_builder_debug = false

        mac = "AA:BB:CC:00:00:01"
        dev = BlueHydra::Device.first(address: mac)
        unless dev
          dev = BlueHydra::Device.new
          dev.address = mac
          dev.save
        end
        report["device_sync_id"] = dev.uuid
        report["db_files_after_save"] = bh_harness_db_files
        report["open_db_files_after_save"] = bh_harness_open_db_files

        File.write(BH_HARNESS_REPORT, JSON.pretty_generate(report))
        # skip bin's ensure (runner is nil) and the real startup
        exit!(0)
      end
    end)
  end
end.enable

# Reports any exit that happens before Runner.new (whose exit! skips this).
at_exit do
  error = $!
  File.write(BH_HARNESS_REPORT, JSON.pretty_generate({
    "events"         => BH_HARNESS_EVENTS,
    "runner_reached" => false,
    "exit"           => {
      "class"  => error&.class&.name,
      "status" => (error.status if error.is_a?(SystemExit)),
      "frames" => (error&.backtrace_locations || []).map { |l| [l.path, l.label] }
    }
  }))
end
