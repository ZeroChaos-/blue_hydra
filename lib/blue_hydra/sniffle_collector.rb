module BlueHydra
  # Simple reader for Sniffle's stdout. It spawns sniff_receiver.py with the
  # configured flags, parses each printed packet block, and feeds BlueHydra
  # result_queue and CUI state.
  class SniffleCollector
    attr_reader :thread

    def initialize(runner)
      @runner = runner
      @result_queue = runner.result_queue
      @stop = false
    end

    def start
      @thread = Thread.new { run }
    end

    def stop
      @stop = true
      @io&.close rescue nil
      @wait_thr&.kill rescue nil
      @thread&.kill
    end

    private

    def run
      cfg = BlueHydra.sniffle_config
      cmd = build_command(cfg)

      @runner.scanner_status[:sniffle] = "starting"

      Open3.popen2e(*cmd) do |_stdin, stdout, wait_thr|
        @wait_thr = wait_thr
        @io = stdout
        buffer = []

        stdout.each_line do |line|
          break if @stop
          # sniff_receiver prints blank lines between packets; use that to flush
          if line.strip.empty?
            process_block(buffer) unless buffer.empty?
            buffer = []
          else
            buffer << line
          end
        end

        process_block(buffer) unless buffer.empty?
      end
    rescue => e
      BlueHydra.logger.error("Sniffle collector error: #{e.message}")
      e.backtrace.each { |ln| BlueHydra.logger.error(ln) }
      @runner.scanner_status[:sniffle] = "error"
    ensure
      @runner.scanner_status[:sniffle] ||= "stopped"
      @runner.scanner_status[:sniffle] = "stopped" if @runner.scanner_status[:sniffle] == "starting"
    end

    def build_command(cfg)
      script = File.expand_path("../../Sniffle/python_cli/sniff_receiver.py", __dir__)
      cmd = ["python3", script]
      cmd += ["-s", cfg["serport"]] if cfg["serport"]
      cmd += ["-b", cfg["baudrate"].to_s] if cfg["baudrate"]
      cmd += ["-c", cfg["advchan"].to_s] if cfg["advchan"]
      cmd << "-e" if cfg["extadv"]

      case cfg["mode"]
      when "active_scan"
        cmd << "-A"
      when "passive_scan"
        cmd << "-a"
      else # conn_follow / default
        # sniff_receiver defaults to connection following
      end

      cmd << "-l" if cfg["longrange"]
      cmd += ["-r", cfg["rssi_min"].to_s] if cfg["rssi_min"]
      cmd += ["-m", cfg["target_mac"]] if cfg["target_mac"]
      cmd += ["-i", cfg["target_irk"]] if cfg["target_irk"]
      cmd += ["-S", cfg["target_string"]] if cfg["target_string"]
      cmd += ["-o", cfg["pcap_output"]] if cfg["pcap_output"]
      cmd
    end

    def process_block(lines)
      attrs = parse_block(lines)
      return unless attrs

      @result_queue.push(attrs)

      # update CUI status similarly to the parser thread
      begin
        tracker = BlueHydra::CliUserInterfaceTracker.new(@runner, [["  LE Sniffle"]], attrs, attrs[:address].first)
        tracker.update_cui_status
      rescue => e
        BlueHydra.logger.debug("Sniffle CUI update error: #{e.message}")
      end

      @runner.scanner_status[:sniffle] = "running"
    end

    def parse_block(lines)
      first = lines[0] || ""
      timestamp = Time.now.to_i
      rssi = (first[/RSSI:\s*(-?\d+)/, 1] || "-99").to_i

      ad_type_line = lines.find { |ln| ln.start_with?("Ad Type:") } || ""
      adv_type = ad_type_line.split(":")[1].to_s.strip

      adv_line = lines.find { |ln| ln.start_with?("AdvA:") }
      return nil unless adv_line
      address = adv_line[/AdvA:\s*([0-9A-Fa-f:]+)/, 1]
      return nil unless address

      addr_note = adv_line[/\(([^)]+)\)/, 1]
      addr_type = addr_note&.downcase&.include?("public") ? "public" : "random"

      bytes = extract_bytes(lines)
      adv_data = extract_adv_data(bytes)
      ad_structs = parse_ad_structs(adv_data)

      attrs = {}
      set_attr(attrs, :address, address.upcase)
      set_attr(attrs, :le_mode, true)
      set_attr(attrs, :last_seen, timestamp)
      set_attr(attrs, :le_rssi, {t: timestamp, rssi: "#{rssi} dBm"})
      set_attr(attrs, :le_address_type, addr_type)
      set_attr(attrs, :le_random_address_type, addr_note) if addr_note

      ad_structs.each do |struct|
        case struct[:type]
        when 0x09, 0x08 # Complete / Shortened local name
          set_attr(attrs, :name, struct[:value])
        when 0x01 # Flags
          set_attr(attrs, :le_flags, struct[:raw_hex])
        when 0x0a # TX Power
          set_attr(attrs, :le_tx_power, struct[:value])
        when 0xff # Manufacturer specific data
          set_attr(attrs, :le_company_data, struct[:raw_hex])
          set_attr(attrs, :company, struct[:company]) if struct[:company]
        when 0x02, 0x03, 0x06, 0x07 # Service UUIDs
          struct[:uuids].each { |uuid| set_attr(attrs, :le_service_uuids, uuid) }
        when 0x19 # Appearance
          set_attr(attrs, :appearance, struct[:appearance]) if struct[:appearance]
        end
      end

      attrs
    end

    def extract_bytes(lines)
      bytes = []
      lines.select { |ln| ln.strip.start_with?("0x") }.each do |ln|
        ln.split(":")[1].to_s.scan(/[0-9A-Fa-f]{2}/).each do |hx|
          bytes << hx.to_i(16)
        end
      end
      bytes
    end

    def extract_adv_data(bytes)
      return [] if bytes.length < 8
      payload_len = bytes[1] || 0
      payload = bytes[2, payload_len] || []
      payload[6..-1] || []
    end

    def parse_ad_structs(ad_bytes)
      structs = []
      i = 0
      while i < ad_bytes.length
        len = ad_bytes[i].to_i
        break if len == 0
        break if (i + len) >= ad_bytes.length + 1

        type = ad_bytes[i + 1]
        value_bytes = ad_bytes[(i + 2)..(i + len)] || []

        case type
        when 0x09, 0x08
          value = bytes_to_utf8(value_bytes)
          structs << {type: type, value: value, raw_hex: hex(value_bytes)}
        when 0x0a
          val = value_bytes.first.to_i
          val -= 256 if val > 127
          structs << {type: type, value: val, raw_hex: hex(value_bytes)}
        when 0xff
          company_id = value_bytes.length >= 2 ? (value_bytes[0] + (value_bytes[1] << 8)) : nil
          company = company_id ? "Company ID 0x#{format('%04x', company_id)}" : nil
          structs << {type: type, company: company, raw_hex: hex(value_bytes)}
        when 0x02, 0x03 # 16-bit UUIDs
          uuids = value_bytes.each_slice(2).map { |pair| format('%04x', (pair[0].to_i + (pair[1].to_i << 8))) }
          structs << {type: type, uuids: uuids, raw_hex: hex(value_bytes)}
        when 0x06, 0x07 # 128-bit UUIDs
          uuids = value_bytes.each_slice(16).map { |blk| hex(blk) }
          structs << {type: type, uuids: uuids, raw_hex: hex(value_bytes)}
        when 0x19
          appearance = value_bytes.length >= 2 ? format('0x%04x', value_bytes[0].to_i + (value_bytes[1].to_i << 8)) : nil
          structs << {type: type, appearance: appearance, raw_hex: hex(value_bytes)}
        else
          structs << {type: type, raw_hex: hex(value_bytes)}
        end

        i += (len + 1)
      end
      structs
    end

    def bytes_to_utf8(bytes)
      bytes.pack('C*').force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
    end

    def hex(bytes)
      bytes.map { |b| format('%02x', b) }.join
    end

    def set_attr(hash, key, val)
      hash[key] ||= []
      hash[key] << val
    end
  end
end
