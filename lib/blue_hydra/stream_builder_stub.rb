module BlueHydra
  # Minimal stand-in for BlueHydra::StreamBuilder, shipped in builds that do not
  # include the full Stream Builder implementation (e.g. the open source
  # release). It mirrors the BlueHydra::Pulse stub pattern: the public methods
  # exist so callers never have to guard on the feature being present.
  #
  # It intentionally contains no transport, routing or protocol details. Its
  # only real behavior is optional debug logging (--stream-builder-debug), which
  # captures the device data and metrics that would be sent to a file, so the
  # debug workflow works even without the full feature installed.
  module StreamBuilder
    DEVICE_DEBUG_LOG  = "stream_builder_debug.log"
    METRICS_DEBUG_LOG = "stream_builder_metrics_debug.log"

    # false: the full Stream Builder implementation is not installed.
    def available?
      false
    end

    # device data sync, debug logged only, nothing is transmitted in this build
    def sync_device(data)
      do_debug(JSON.generate(data)) if BlueHydra.stream_builder_debug
    end

    # aggressive rssi sync, debug logged only
    def sync_aggressive_rssi(data)
      do_debug(JSON.generate(data)) if BlueHydra.stream_builder_debug
    end

    # metric, debug logged only
    def send_event(name, value, dimensions: [], unit: nil, namespace: nil)
      if BlueHydra.stream_builder_debug
        do_metrics_debug(JSON.generate({
          "metric"     => name,
          "value"      => value,
          "dimensions" => dimensions,
          "unit"       => unit,
          "namespace"  => namespace
        }))
      end
    end

    # nothing is batched in this build
    def flush_device_sync_counts!; end

    # append device data json to the device debug log
    def do_debug(json)
      File.open(DEVICE_DEBUG_LOG, 'a') { |file| file.puts(json) }
    end

    # append metric json to the metrics debug log
    def do_metrics_debug(json)
      File.open(METRICS_DEBUG_LOG, 'a') { |file| file.puts(json) }
    end

    module_function :available?, :sync_device, :sync_aggressive_rssi,
                    :send_event, :flush_device_sync_counts!,
                    :do_debug, :do_metrics_debug
  end
end
