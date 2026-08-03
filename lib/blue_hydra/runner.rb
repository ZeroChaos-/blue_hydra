module BlueHydra

  # This class is a wrapper for all the core functionality of  Blue Hydra. It
  # is responsible for managing all the threads for device interaction, data
  # processing and, when not in daemon mode, the CLI UI thread and tracker.
  class Runner

    attr_accessor :command,
                  :raw_queue,
                  :chunk_queue,
                  :result_queue,
                  :btmon_thread,
                  :discovery_thread,
                  :ubertooth_thread,
                  :chunker_thread,
                  :parser_thread,
                  :signal_spitter_thread,
                  :empty_spittoon_thread,
                  :cui_status,
                  :cui_thread,
                  :api_thread,
                  :info_scan_queue,
                  :query_history,
                  :scanner_status,
                  :l2ping_queue,
                  :result_thread,
                  :stunned,
                  :processing_speed,
                  :mgmt,
                  :hci,
                  :auto_connect_list,
                  :le_pending,
                  :le_info_scan_queue

    # if we have been passed the 'file' option in the config we should try to
    # read out the file as our data source. This allows for btmon captures to
    # be replayed and post-processed.
    #
    # Supported filetypes are .xz, .gz or plaintext
    if BlueHydra.config["file"]
      if BlueHydra.config["file"] =~ /\.xz$/
        @@command = "xzcat #{BlueHydra.config["file"]}"
      elsif BlueHydra.config["file"] =~ /\.gz$/
        @@command = "zcat #{BlueHydra.config["file"]}"
      else
        @@command = "cat #{BlueHydra.config["file"]}"
      end
    else
      # Why is --columns here? Because Bluez 5.72 crashes without it
      @@command = "btmon --columns 170 -T -i #{BlueHydra.config["bt_device"]}"
    end
    if ! ::File.executable?(`command -v #{@@command.split[0]} 2> /dev/null`.chomp)
      BlueHydra.logger.fatal("Failed to find: '#{@@command.split[0]}' which is needed for the current setting...")
      exit 1
    end

    # Start the runner after being initialized
    #
    # == Parameters
    #   command ::
    #     the command to run, typically btmon -T -i hci0 but will be different
    #     if running in file mode
    def start(command=@@command)
      @stopping = false
      begin
        BlueHydra.logger.debug("Runner starting with command: '#{command}' ...")

        # Check if we have any devices
        if !BlueHydra::Device.first.nil?
          #If we have devices, make sure to clean up their states and sync it all

          # Since it is unknown how long it has been since the system run last
          # we should look at the DB and mark timed out devices as offline before
          # starting anything else
          BlueHydra.logger.info("Marking older devices as 'offline'...")
          BlueHydra::Device.mark_old_devices_offline(true)

          # Sync everything to pwnpulse if the system is connected to the Pwnie
          # Express cloud
          BlueHydra.logger.info("Syncing all hosts to Pulse...") if BlueHydra.pulse
          BlueHydra::Device.sync_all_to_pulse

          # Sync everything to Stream Builder if enabled (Anemoi platform)
          BlueHydra.logger.info("Syncing all hosts to Stream Builder...") if BlueHydra.stream_builder
          BlueHydra::Device.sync_all_to_stream_builder
        else
          BlueHydra.logger.info("No devices found in DB, starting clean.")
        end
        BlueHydra::Pulse.reset

        # Query History is used to track what addresses have been pinged
        self.query_history   = {}

        # Devices currently in the kernel LE auto-connect list (mgmt Add Device),
        # keyed by address => {address_type:, added_at:, connected:}. Bounded by
        # CONNECT_PENDING_LIMIT; entries are removed event-driven during the
        # CONNECT phase (Device Disconnected/Connect Failed) or cleared when the
        # phase ends.
        self.auto_connect_list = {}

        # LE info-scan requests waiting for a slot in the auto-connect list,
        # keyed by address => le_address_type (FIFO, deduped). Requests are held
        # here (never dropped) when the auto-connect list is full.
        self.le_pending = {}

        # Stunned
        self.stunned = false

        # the command used to capture data
        self.command         = command

        # various queues used for thread intercommunication, could be replaced
        # by true IPC sockets at some point but these work prety damn well
        self.raw_queue          = Queue.new # btmon thread   -> chunker thread
        self.chunk_queue        = Queue.new # chunker thread -> parser thread
        self.result_queue       = Queue.new # parser thread  -> result thread
        self.info_scan_queue    = Queue.new # result thread  -> discovery thread (classic)
        self.le_info_scan_queue = Queue.new # result thread  -> discovery thread (LE, serviced during discovery)
        self.l2ping_queue       = Queue.new # result thread  -> discovery thread

        # start the result processing thread
        start_result_thread

        # RSSI API
        if BlueHydra.signal_spitter
          @rssi_data_mutex = Mutex.new #this is used by parser thread too
          start_signal_spitter_thread
          start_empty_spittoon_thread
        end

        # start the thread responsible for parsing the chunks into little data
        # blobs to be sorted in the db
        start_parser_thread

        # start the thread responsible for breaking the filtered btmon output
        # into chunks by device, basically a pre-parser
        start_chunker_thread

        # start the thread which runs the command, typically btmon so this is
        # the btmon thread but this thread will also run the xzcat, zcat or cat
        # commands for files
        start_btmon_thread

        # helper hashes for tracking status of the scanners and also the in
        # memory copy of data for the CUI
        self.scanner_status  = {}
        self.cui_status      = {}

        # another thread which operates the actual device discovery, not needed
        # if reading from a file since btmon will just be getting replayed
        unless ENV["BLUE_HYDRA"] == "test"
          start_discovery_thread unless BlueHydra.config["file"]
        end

        # start the thread responsible for printing the CUI to screen unless
        # we are in daemon mode
        start_cui_thread unless BlueHydra.daemon_mode

        # start the thread responsible for printing the file api if requested
        start_api_thread if BlueHydra.file_api

        # unless we are reading from a file we need to determine if we have an
        # ubertooth available and then initialize a thread to manage that
        # device as needed
        unless BlueHydra.config["file"]
          #I am hoping this sleep randomly fixing the display issue in cui
          sleep 1
          # Handle ubertooth
          # add in additional hardware detection using `lsusb -d 1d50:6002` exit code
          if ::File.executable?(`command -v lsusb 2> /dev/null`.chomp)
            self.scanner_status[:ubertooth] = "lsusb available"
            lsusb = BlueHydra::Command.execute3("lsusb -d '1d50:6002'")
            if lsusb[:exit_code] == 0
              self.scanner_status[:ubertooth] = "Hardware found, checking for ubertooth-util"
              if ::File.executable?(`command -v ubertooth-util 2> /dev/null`.chomp)
                self.scanner_status[:ubertooth] = "Detecting"
                ubertooth_util_v = BlueHydra::Command.execute3("ubertooth-util -v -U #{BlueHydra.config["ubertooth_index"]}")
                if ubertooth_util_v[:exit_code] == 0
                  self.scanner_status[:ubertooth] = "Found hardware"
                  BlueHydra.logger.debug("Found ubertooth hardware")
                  sleep 1
                  ubertooth_util_r = BlueHydra::Command.execute3("ubertooth-util -r -U #{BlueHydra.config["ubertooth_index"]}")
                  if ubertooth_util_r[:exit_code] == 0
                    self.scanner_status[:ubertooth] = "hardware responsive"
                    BlueHydra.logger.debug("hardware is responsive")
                    sleep 1
                    if system("ubertooth-rx -h 2>&1 | grep -q Survey")
                      BlueHydra.logger.debug("Found working ubertooth-rx -z")
                      self.scanner_status[:ubertooth] = "ubertooth-rx"
                      ubertooth_rx_firmware = BlueHydra::Command.execute3("ubertooth-rx -z -t 1 -U #{BlueHydra.config["ubertooth_index"]}")
                      ubertooth_firmware_check(ubertooth_rx_firmware[:stderr])
                      if ubertooth_rx_firmware[:exit_code] == 0
                        @ubertooth_command = "ubertooth-rx -z -t 40 -U #{BlueHydra.config["ubertooth_index"]}"
                      end
                    end
                    unless @ubertooth_command
                      sleep 1
                      ubertooth_scan_firmware = BlueHydra::Command.execute3("ubertooth-scan -t 1 -U #{BlueHydra.config["ubertooth_index"]}")
                      ubertooth_firmware_check(ubertooth_scan_firmware[:stderr])
                      if ubertooth_scan_firmware[:exit_code] == 0
                        BlueHydra.logger.debug("Found working ubertooth-scan")
                        self.scanner_status[:ubertooth] = "ubertooth-scan"
                        @ubertooth_command = "ubertooth-scan -t 40 -U #{BlueHydra.config["ubertooth_index"]}"
                      else
                        if self.scanner_status[:ubertooth] != 'Disabled, firmware upgrade required'
                          BlueHydra.logger.error("Unable to find ubertooth-scan or ubertooth-rx -z, ubertooth disabled.")
                          self.scanner_status[:ubertooth] = "Unable to find ubertooth-scan or ubertooth-rx -z"
                        end
                      end
                    end
                  else
                    self.scanner_status[:ubertooth] = "hardware unresponsive"
                    if !ubertooth_util_r[:stdout].nil? && ubertooth_util_r[:stdout] != ""
                      ubertooth_util_r[:stdout].split("\n").each do |ln|
                        BlueHydra.logger.debug(ln)
                      end
                    end
                    if !ubertooth_util_r[:stderr].nil? && ubertooth_util_r[:stderr] != ""
                      ubertooth_util_r[:stderr].split("\n").each do |ln|
                        BlueHydra.logger.debug(ln)
                      end
                    end
                    BlueHydra.logger.error("hardware is present but ubertooth-util -r fails")
                  end
                  start_ubertooth_thread if @ubertooth_command
                else
                  self.scanner_status[:ubertooth] = "No hardware detected"
                  if !ubertooth_util_v[:stdout].nil? && ubertooth_util_v[:stdout] != ""
                    ubertooth_util_v[:stdout].split("\n").each do |ln|
                      BlueHydra.logger.debug(ln)
                    end
                  end
                  if !ubertooth_util_v[:stderr].nil? && ubertooth_util_v[:stderr] != ""
                    ubertooth_util_v[:stderr].split("\n").each do |ln|
                      BlueHydra.logger.debug(ln)
                    end
                  end
                  BlueHydra.logger.info("No ubertooth hardware detected")
                end
              else
                self.scanner_status[:ubertooth] = "ubertooth-util missing"
                BlueHydra.logger.info("Unable to use ubertooth without ubertooth-util installed")
              end
            else
              self.scanner_status[:ubertooth] = "No hardware detected"
            end
          else
            self.scanner_status[:ubertooth] = "Please install lsusb"
            BlueHydra.logger.info("Unable to detect ubertooth without lsusb installed")
          end
        end

      rescue => e
        BlueHydra.logger.error("Runner master thread: #{e.message}")
        e.backtrace.each do |x|
          BlueHydra.logger.error("#{x}")
        end
        BlueHydra.send_event('blue_hydra',
        {key: 'blue_hydra_master_thread_error',
        title: 'Blue Hydras Master Thread Encountered An Error',
        message: "Runner master thread: #{e.message}",
        severity: 'ERROR'
        })
      end
    end

    # this is a helper method which resports status of queue depth and thread
    # health. Mainly used from bin/blue_hydra work loop to make sure everything
    # is alive or to exit gracefully
    def status
      x = {
        raw_queue:         self.raw_queue.length,
        chunk_queue:       self.chunk_queue.length,
        result_queue:      self.result_queue.length,
        info_scan_queue:   self.info_scan_queue.length,
        le_info_scan_queue: self.le_info_scan_queue.length,
        l2ping_queue:      self.l2ping_queue.length,
        btmon_thread:      self.btmon_thread.status,
        chunker_thread:    self.chunker_thread.status,
        parser_thread:     self.parser_thread.status,
        result_thread:     self.result_thread.status,
        stopping:          @stopping
      }

      unless BlueHydra.config["file"]
        x[:discovery_thread] = self.discovery_thread.status
        x[:ubertooth_thread] = self.ubertooth_thread.status if self.ubertooth_thread
      end

      if BlueHydra.signal_spitter
        x[:signal_spitter_thread] = self.signal_spitter_thread.status
        x[:empty_spittoon_thread] = self.empty_spittoon_thread.status
      end

      x[:cui_thread] = self.cui_thread.status unless BlueHydra.daemon_mode
      x[:api_thread] = self.api_thread.status if BlueHydra.file_api

      x
    end

    # stop method this stops the threads but attempts to allow the result queue
    # to drain before fully exiting to prevent data loss
    def stop
      return if @stopping
      @stopping = true
      BlueHydra.logger.info("Runner stopped. Exiting after clearing queue...")
      if self.btmon_thread
        self.btmon_thread.kill # stop this first thread so data stops flowing ...
        # ...then wait for it to actually finish unwinding. Its ensure closes
        # the btmon gzip log(s), which writes the gzip trailer; without joining
        # here that close races with process teardown and can leave a truncated
        # ("unexpected end of file") log. Bounded so a wedged thread can't hang
        # shutdown.
        self.btmon_thread.join(5)
      end
      unless BlueHydra.config["file"] #then stop doing anything if we are doing anything
        self.discovery_thread.kill if self.discovery_thread
        self.ubertooth_thread.kill if self.ubertooth_thread
        if self.mgmt
          # Clear anything we left in the kernel (auto-connect list, open
          # connections) with a final reset before closing the control socket.
          # A power-cycle drops the kernel's auto-connect (Add Device) entries
          # so the controller isn't left background-connecting our devices after
          # we exit. Best effort - never let shutdown hang on it.
          begin
            hci_reset
          rescue => e
            BlueHydra.logger.error("mgmt reset on shutdown failed: #{e.message}")
          end
          # close the shared mgmt control socket now that the discovery thread
          # (its only user) has stopped issuing commands
          self.mgmt.close
        end

        if self.hci
          # close the raw HCI version-read socket / reader thread
          begin
            self.hci.close
          rescue => e
            BlueHydra.logger.error("hci socket close on shutdown failed: #{e.message}")
          end
        end
      end

      stop_condition = Proc.new do
        [nil, false].include?(result_thread.status) ||
        [nil, false].include?(parser_thread.status) ||
        self.result_queue.empty?
      end

      # clear queue...
      until stop_condition.call
        unless self.cui_thread
          BlueHydra.logger.info("Remaining queue depth: #{self.result_queue.length}")
          sleep 5
        else
          sleep 1
        end
      end

      # flush any remaining accumulated device sync counts to Stream Builder
      # so the final partial interval is not lost on shutdown
      BlueHydra::StreamBuilder.flush_device_sync_counts!

      if BlueHydra.no_db
        # when we know we are storing no database it makes no sense to leave the devices online
        # tell pulse in advance that we are clearing this database so things do not get confused
        # when bringing an older database back online
        # this is our protection against running "blue_hydra; blue_hydra --no-db; blue_hydra"
        BlueHydra.logger.info("Queue clear! Resetting Pulse then exiting.")
        BlueHydra::Pulse.reset
        BlueHydra.logger.info("Pulse reset! Exiting.")
      else
        BlueHydra.logger.info("Queue clear! Exiting.")
      end

      self.chunker_thread.kill        if self.chunker_thread
      self.parser_thread.kill         if self.parser_thread
      self.result_thread.kill         if self.result_thread
      self.api_thread.kill            if self.api_thread
      self.cui_thread.kill            if self.cui_thread
      self.signal_spitter_thread.kill if self.signal_spitter_thread
      self.empty_spittoon_thread.kill if self.empty_spittoon_thread

      self.raw_queue          = nil
      self.chunk_queue        = nil
      self.result_queue       = nil
      self.info_scan_queue    = nil
      self.le_info_scan_queue = nil
      self.l2ping_queue       = nil
    end

    # Start the thread which runs the specified command
    def start_btmon_thread
      BlueHydra.logger.info("Btmon thread starting")
      self.btmon_thread = Thread.new do
        begin
          # spawn the handler for btmon and pass in the shared raw queue as a
          # param so that it can feed data back into the runner threads
          spawner = BlueHydra::BtmonHandler.new(
            self.command,
            self.raw_queue
          )
        rescue BtmonExitedError
          BlueHydra.logger.error("Btmon thread exiting...")
          BlueHydra.send_event('blue_hydra',
            {key: 'blue_hydra_btmon_exited',
          title: 'Blue Hydras Btmon Thread Exited',
          message: "Btmon Thread exited...",
          severity: 'ERROR'
          })
        rescue => e
          BlueHydra.logger.error("Btmon thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
          BlueHydra.send_event('blue_hydra',
          {key: 'blue_hydra_btmon_thread_error',
          title: 'Blue Hydras BTmon Thread Encountered An Error',
          message: "Btmon thread #{e.message}",
          severity: 'ERROR'
          })
        end
      end
    end

    def ubertooth_firmware_check(ubertooth_stderr)
      if ubertooth_stderr =~ /Please upgrade to latest released firmware/
        self.scanner_status[:ubertooth] = 'Disabled, firmware upgrade required'
        BlueHydra.logger.error("Ubertooth disabled, firmware upgrade required to match host software")
        ubertooth_stderr.split("\n").each do |ln|
          BlueHydra.logger.error(ln)
        end
        return false
      end
      return true
    end

    # Run a single discovery cycle using the kernel Bluetooth mgmt API. This
    # replaces the external dbus `test-discovery` helper: it cooperates with
    # bluetoothd at the kernel level instead of fighting it at the raw hci
    # layer. Starts discovery, lets it run for +discovery_time+ seconds, then
    # stops it. If the controller is not ready, BlueHydra::Mgmt attempts rfkill
    # recovery and, failing that, raises BluezNotReadyError for us to escalate.
    def run_mgmt_discovery(discovery_time)
      # Reset before enabling discovery (the SCAN-on transition). SAFE here: the
      # previous CONNECT phase cleared auto_connect_list, so the kernel auto-
      # connect list is empty at this point. The power-cycle re-initializes the
      # controller, which restores the kernel's post-connection interrogation
      # (Read Remote Version) that version reads depend on - removing this reset
      # (item 9) is what regressed version reads (item 19).
      hci_reset

      status = mgmt.start_discovery
      unless status == BlueHydra::Mgmt::STATUS_SUCCESS
        BlueHydra.logger.error("mgmt start discovery failed (status 0x%02x)" % status)
        return
      end

      # Info scan disabled: stay in continuous discovery (the reader thread keeps
      # it alive) - no CONNECT phase, since nothing is enqueued for LE/classic
      # info in that mode. l2ping still runs in the discovery-thread drain (gated
      # only by file-replay mode), briefly suppressing discovery per probe.
      unless BlueHydra.info_scan
        sleep discovery_time
        return
      end

      # SCAN phase (discovery on): populate the auto-connect list. Then, only if
      # we queued anything, a CONNECT phase to let those devices connect.
      scan_phase(discovery_time)
      connect_phase unless auto_connect_list.empty?
    end

    # SCAN phase: keep discovery on and feed the auto-connect list. Devices are
    # added ONLY here, while discovering. No TTL sweep - the list accumulates
    # freshly-requested advertisers up to CONNECT_PENDING_LIMIT; overflow waits
    # (never dropped) in le_pending for the next round.
    def scan_phase(seconds)
      deadline = Time.now + seconds
      while Time.now < deadline
        sleep 1
        service_le_info_scans

        # Prune devices that have finished their connect/interrogate/disconnect
        # cycle BEFORE topping the list back up. The kernel's ACTION_AUTO_CONNECT
        # reconnects a device on every advertisement until we Remove Device, so
        # a device left in the list is re-connected over and over for the whole
        # scan window (observed: 10 devices producing 65 connections). Removing
        # it as soon as its first cycle completes stops that churn; the freed
        # slot lets fill_auto_connect pipeline in the next pending device.
        process_connection_events

        fill_auto_connect
        break if self.auto_connect_list.size >= CONNECT_PENDING_LIMIT
      end
    end

    # CONNECT phase: suppress discovery so the kernel's auto-connect scan gets
    # the radio, then react to mgmt connection events until the pending set
    # empties (primary exit) or DISCOVERY_OFF_BUDGET elapses (sole time-based
    # safety net). No new devices are added here. On exit the auto-connect list
    # is cleared so the in-memory view matches the kernel, and discovery resumes
    # on the next cycle's start_discovery (which clears the suppression flag).
    def connect_phase
      drain_connection_events
      disable_scan_before_connect # sets @discovery_suppressed + Stop Discovery
      deadline = Time.now + DISCOVERY_OFF_BUDGET
      loop do
        process_connection_events
        break if self.auto_connect_list.empty? # primary exit: all queries done
        break if Time.now >= deadline          # safety net
        sleep 0.1
      end
      clear_auto_connect
    end

    # Drain the LE info-scan queue into the auto-connect machinery. Must run only
    # from the discovery thread (it touches le_pending / auto_connect_list).
    # request_leinfo holds overflow in le_pending (never dropped), so it is safe
    # to drain the whole queue here.
    def service_le_info_scans
      until le_info_scan_queue.empty?
        request = le_info_scan_queue.pop
        request_leinfo(request[:address], request[:le_address_type])
      end
    end

    # Controller index (the N in hciN) parsed from the configured bt_device.
    def mgmt_index
      BlueHydra.config["bt_device"][/\d+/].to_i
    end

    # Run a connect-based classic scan (the block returns the command's stderr,
    # or nil on success). Stage B of item 9: instead of power-cycling the
    # controller before every connect, we try once and only hci_reset + retry
    # once if the connection itself failed in a way a reset may clear (see
    # RESET_WORTHY_CONNECT_ERROR). Returns the final stderr.
    def scan_with_reset_retry
      errors = yield
      if errors && errors =~ RESET_WORTHY_CONNECT_ERROR
        BlueHydra.logger.debug("connect failed (#{errors.chomp}); resetting and retrying once")
        hci_reset
        errors = yield
      end
      errors
    end

    # Keep contiguous discovery-off time within DISCOVERY_OFF_BUDGET during the
    # classic/l2ping drain. Called BETWEEN per-device operations: if discovery
    # has been off at least the budget since +off_since+, resume discovery for a
    # short RESUME_DISCOVERY_WINDOW so scanning actually happens, then return a
    # fresh off_since. Otherwise returns off_since unchanged. A single in-flight
    # operation can still overrun the budget (it cannot be interrupted); this
    # bounds the off-time across a backlog of operations.
    def resume_discovery_if_over_budget(off_since)
      return off_since if (Time.now - off_since) < DISCOVERY_OFF_BUDGET
      mgmt.start_discovery
      sleep RESUME_DISCOVERY_WINDOW
      Time.now
    end

    # Maximum devices allowed in the kernel LE auto-connect list at once.
    AUTO_CONNECT_LIMIT = 32

    # Single bound (seconds) on how long discovery may be continuously off - the
    # CONNECT phase and the classic drain. Sized above the observed worst-case
    # single operation (LE connect ~5.5s). Sole time-based safety net.
    DISCOVERY_OFF_BUDGET = 6
    # Max devices we admit into a single CONNECT phase (<= AUTO_CONNECT_LIMIT).
    CONNECT_PENDING_LIMIT = AUTO_CONNECT_LIMIT
    # Small scanning window inserted into a long classic drain when the
    # discovery-off budget is exceeded, so scanning actually happens.
    RESUME_DISCOVERY_WINDOW = 2
    # Bounded connect timeout for the native L2CAP reachability probe.
    L2CAP_CONNECT_TIMEOUT = 4

    # hcitool/l2ping connect errors that a controller reset may clear, as
    # opposed to "no route to host" / "host is down" (the device is simply not
    # reachable, so a reset would not help). Used to decide whether to reset and
    # retry a failed classic connect (item 9, stage B).
    RESET_WORTHY_CONNECT_ERROR = /create connection: (Input\/output|I\/O) error|Command Disallowed/i

    # Request an LE info scan for a device. The request is NEVER dropped: if the
    # kernel auto-connect list is full (AUTO_CONNECT_LIMIT) the device waits in
    # le_pending (a FIFO, deduped by address) until a slot frees up. Devices that
    # are already in the auto-connect list are ignored (already being handled).
    def request_leinfo(address, le_address_type)
      return if self.auto_connect_list.key?(address)
      # Hash keeps insertion order (FIFO) and dedupes by address; re-requests
      # just refresh the stored address type without losing queue position.
      self.le_pending[address] = le_address_type
      fill_auto_connect
    end

    # Promote as many pending LE devices into the auto-connect list as will fit
    # (up to CONNECT_PENDING_LIMIT). Called during the SCAN phase and on each new
    # request so pending devices flow in as slots free. No TTL sweep - entries
    # are removed event-driven during the CONNECT phase, not by aging here.
    def fill_auto_connect
      while self.auto_connect_list.size < CONNECT_PENDING_LIMIT && !self.le_pending.empty?
        address         = self.le_pending.keys.first
        le_address_type = self.le_pending.delete(address)
        add_to_auto_connect(address, le_address_type)
      end
    end

    # Add one LE device to the kernel auto-connect list (mgmt Add Device,
    # auto-connect action) and record it. Capacity is the caller's
    # responsibility (see fill_auto_connect); this just performs the add.
    def add_to_auto_connect(address, le_address_type)
      addr_type = mgmt_le_address_type(le_address_type)
      status    = mgmt.add_device(address, addr_type)
      if status == BlueHydra::Mgmt::STATUS_SUCCESS
        self.auto_connect_list[address] = { address_type: addr_type, added_at: Time.now, connected: false }
        BlueHydra::CliUserInterfaceTracker.increment_auto_connect_added_count
      else
        # a mgmt-level add failure is logged and not re-queued (it would be
        # re-requested next info_scan_rate cycle anyway); the pending-queue hold
        # is only for the capacity case, which fill_auto_connect handles.
        BlueHydra.logger.error("mgmt add device failed for #{address} (status 0x%02x)" % status)
      end
    end

    # Remove a single device from the auto-connect list (mgmt Remove Device) and
    # drop our bookkeeping for it.
    def remove_from_auto_connect(address)
      entry = self.auto_connect_list.delete(address)
      return unless entry
      status = mgmt.remove_device(address, entry[:address_type])
      unless status == BlueHydra::Mgmt::STATUS_SUCCESS
        BlueHydra.logger.error("mgmt remove device failed for #{address} (status 0x%02x)" % status)
      end
    end

    # Map the parsed le_address_type ("Public"/"Random") to the mgmt Add Device
    # LE address_type byte. Defaults to LE Random when the type is unknown.
    def mgmt_le_address_type(le_address_type)
      le_address_type.to_s =~ /public/i ? BlueHydra::Mgmt::LE_PUBLIC : BlueHydra::Mgmt::LE_RANDOM
    end

    # Drain the mgmt connection-event queue and use each event to manipulate the
    # auto-connect list. Runs only on the discovery thread (sole mutator of
    # auto_connect_list). Disconnect/failed remove the device immediately -
    # faster than any timer (Req 3.5); connected marks the entry connected and
    # keeps it pending; events for addresses we are not tracking are ignored.
    def process_connection_events
      return unless mgmt
      loop do
        event =
          begin
            mgmt.connection_events.pop(true)
          rescue ThreadError
            break # queue empty
          end
        address = event[:address]
        entry   = self.auto_connect_list[address]
        next unless entry # not a device this cycle is tracking
        case event[:type]
        when :connected
          entry[:connected] = true
          BlueHydra::CliUserInterfaceTracker.increment_auto_connect_connected_count
        when :disconnected
          # queries done for this device -> remove now, beating any timeout
          remove_from_auto_connect(address)
        when :failed
          BlueHydra::CliUserInterfaceTracker.increment_auto_connect_failed_count
          remove_from_auto_connect(address)
        end
      end
    end

    # Discard any connection events left over from a prior phase so the CONNECT
    # phase only reacts to events for the devices it just added.
    def drain_connection_events
      mgmt.connection_events.clear if mgmt
    end

    # Remove every remaining auto-connect entry (mgmt Remove Device) so the
    # in-memory list matches the kernel state at the end of a CONNECT phase.
    def clear_auto_connect
      self.auto_connect_list.keys.each { |address| remove_from_auto_connect(address) }
    end

    # Stop device discovery/scanning via the mgmt API before an info-scan
    # connection attempt. See the call site in start_discovery_thread for the
    # full rationale (in short: hcitool's LE Create Connection is rejected with
    # "Command Disallowed" while the controller is still scanning). Best effort:
    # any failure is logged and swallowed so a flaky mgmt socket never blocks
    # the info scan.
    #
    # TODO: remove this in a future release to improve speed. Once the info-scan
    # connection is itself driven through the mgmt API (cooperatively with
    # bluetoothd) this explicit per-connect stop is redundant, and its extra
    # socket round-trip is pure added latency in the scan/info-scan cycle.
    def disable_scan_before_connect
      mgmt.stop_discovery
    rescue => e
      BlueHydra.logger.error("mgmt stop discovery before connect failed: #{e.message}")
    end

    # helper method to reset the interface as needed
    #
    # Uses the kernel Bluetooth mgmt API (Set Powered off then on) instead of
    # shelling out to `hciconfig reset` + `bluetoothctl power on`. Powering the
    # controller off clears its state (open connections, scanning) and powering
    # it back on readies it - the cooperative, kernel-level equivalent of the
    # old reset that no longer needs bluetoothd on the dbus. If the controller
    # is not ready, BlueHydra::Mgmt attempts rfkill recovery internally and, if
    # that fails, raises BluezNotReadyError for start_discovery_thread to
    # escalate.
    def hci_reset
      status = mgmt.set_powered(false)
      BlueHydra.logger.error("mgmt power off failed (status 0x%02x)" % status) unless status == BlueHydra::Mgmt::STATUS_SUCCESS

      # Bluez 5.64 seems to have a bug in reset where the device shows powered
      # but fails as not ready, so pause between power off and power on.
      sleep 1

      status = mgmt.set_powered(true)
      BlueHydra.logger.error("mgmt power on failed (status 0x%02x)" % status) unless status == BlueHydra::Mgmt::STATUS_SUCCESS

      sleep 1
    end

    # thread responsible for sending interesting commands to the hci device so
    # that interesting things show up in the btmon ouput
    def start_discovery_thread
      BlueHydra.logger.info("Discovery thread starting")
      self.discovery_thread = Thread.new do
        begin

          # Open a single mgmt control socket for the life of the discovery
          # thread and reuse it for every command (reset, discovery, disable
          # scan). BlueHydra::Mgmt opens lazily on first use and transparently
          # reopens if the socket is ever closed unexpectedly, so we just hold
          # the instance here and close it in #stop.
          self.mgmt = BlueHydra::Mgmt.new(mgmt_index)

          # Dedicated raw-HCI reader that issues Read Remote Version Information
          # for each LE connection the kernel opens (the kernel auto-reads LE
          # features but never the version). Its own thread keeps this as close
          # to real time as possible so the command lands inside the brief
          # connected window. Closed in #stop alongside mgmt.
          self.hci = BlueHydra::HciCommand.new(mgmt_index)
          self.hci.start

          # Native L2CAP reachability probe (replaces the external l2ping
          # subprocess). Reused for every l2ping-queue entry this thread drains.
          l2ping_probe = BlueHydra::L2Ping.new(mgmt_index, connect_timeout: L2CAP_CONNECT_TIMEOUT)

          # We only read device info, never bond. Configure the controller
          # non-bondable + NoInputNoOutput once so info/reachability connects
          # don't create bonds or trigger PIN/passkey prompts (the mgmt reader
          # also auto-rejects any pairing-request events). Best effort.
          mgmt.configure_no_pairing

          if BlueHydra.info_scan
            discovery_time = 30
          else
            discovery_time = 60
          end

          loop do
            begin

              # Reset before the classic connect phase, when there is classic
              # info / l2ping work to do. SAFE here: auto_connect_list was
              # cleared at the end of the previous CONNECT phase, so the kernel
              # auto-connect list is empty and the reset cannot wipe live
              # entries. Restores the clean controller state classic connects
              # benefit from (same rationale as the pre-discovery reset).
              unless info_scan_queue.empty? && l2ping_queue.empty?
                hci_reset
              end

              # clear the queues. Track when discovery went off so we can yield
              # back to scanning between operations if the drain runs long
              # (bounds contiguous discovery-off time to DISCOVERY_OFF_BUDGET).
              off_since = Time.now
              until info_scan_queue.empty? && l2ping_queue.empty?
                # clear out entire info scan queue first
                until info_scan_queue.empty?
                  # yield to discovery between ops if we have been off too long
                  off_since = resume_discovery_if_over_budget(off_since)
                  BlueHydra.logger.debug("Popping off info scan queue. Depth: #{ info_scan_queue.length}")

                  # grab a command out of the queue to run
                  command = info_scan_queue.pop
                  case command[:command]
                  when :info # classic mode devices
                    # stop scanning before the classic connection (stage C will
                    # revisit whether classic connects actually need this).
                    disable_scan_before_connect

                    # run hcitool info against the specified address, capture
                    # errors, no need to capture stdout because the interesting
                    # stuff is gonna be in btmon anyway. Try once without a reset
                    # and only reset+retry if the connection failed (stage B).
                    info_errors = scan_with_reset_retry do
                      BlueHydra::Command.execute3("hcitool -i #{BlueHydra.config["bt_device"]} info #{command[:address]}",3)[:stderr]
                    end

                    # handle and log error output as needed
                    if info_errors
                      if info_errors.chomp =~ /connect: No route to host/i
                        # We could handle this as negative feedback if we want
                      elsif info_errors.chomp =~ /create connection: Input\/output error/i
                        # We failed to connect, not sure why, not sure we care
                      else
                        BlueHydra.logger.error("Error with info command... #{command.inspect}")
                        info_errors.split("\n").each do |ln|
                          BlueHydra.logger.error(ln)
                        end
                      end
                    end

                  else
                    # LE info scans no longer come through this queue; they are
                    # serviced during the SCAN phase (see scan_phase /
                    # service_le_info_scans). Anything else is unexpected.
                    BlueHydra.logger.error("Invalid command detected... #{command.inspect}")
                  end

                end

                # run 1 l2ping a time while still checking if info scan queue
                # is empty
                unless l2ping_queue.empty?
                  # yield to discovery between ops if we have been off too long
                  off_since = resume_discovery_if_over_budget(off_since)
                  # Disable scanning before the l2ping connection, same as the
                  # info-scan connect above (stage C will revisit this).
                  disable_scan_before_connect

                  BlueHydra.logger.debug("Popping off l2ping queue. Depth: #{ l2ping_queue.length}")
                  command = l2ping_queue.pop
                  # Native L2CAP reachability probe replaces shelling out to
                  # l2ping: it pages the device (raising the ACL link that btmon
                  # captures for parsing) and returns as soon as reachability is
                  # known, with no echo exchange. A socket-level :error is
                  # treated as reset-worthy so scan_with_reset_retry hci_resets
                  # and retries once, mirroring the old connect-failure retry;
                  # :reachable / :unreachable need no retry.
                  probe_error = scan_with_reset_retry do
                    l2ping_probe.reach?(command[:address]) == :error ? "create connection: I/O error" : nil
                  end
                  if probe_error
                    BlueHydra.logger.error("Error with l2ping probe... #{command.inspect}")
                  end
                end
              end

              # NOTE: we used to hci_reset (power-cycle) here before every
              # discovery cycle. That is unnecessary now that discovery is
              # continuous (the mgmt reader thread re-arms it) - power-cycling
              # just tore the adapter down and re-initialized it each loop and
              # fought the continuous scan. Removed (item 9, stage A). Resets now
              # only happen on actual error/recovery paths.

              # hot loop avoidance, but run right before discovery to avoid any delay between discovery and info scan
              sleep 1

              # run a discovery cycle via the kernel mgmt API (replaces the
              # external dbus test-discovery helper)
              run_mgmt_discovery(discovery_time)

            rescue BluezNotReadyError
              # BlueHydra::Mgmt has already attempted rfkill recovery and could
              # not bring #{bt_device} back, so this is unrecoverable - escalate.
              unless BlueHydra.daemon_mode
                self.cui_thread.kill if self.cui_thread
                puts "Bluez reported #{BlueHydra.config["bt_device"]} not ready and failed to auto-reset with rfkill"
                puts "Try removing and replugging the card, or toggling rfkill on and off"
              end
              BlueHydra.logger.fatal("Bluez reported #{BlueHydra.config["bt_device"]} not ready and failed to reset with rfkill")
              BlueHydra.send_event('blue_hydra',
              {key: 'blue_hydra_bluez_error',
              title: 'Blue Hydra Encountered Bluez Error',
              message: "Bluez reported #{BlueHydra.config["bt_device"]} not ready and failed to reset with rfkill",
              severity: 'FATAL'
              })
              exit 1
            rescue MgmtSocketError => e
              # BlueHydra::Mgmt already emitted a specific socket-error event
              # before giving up, so don't send a duplicate generic one here.
              # Back off and let the loop retry - the adapter may re-enumerate.
              BlueHydra.logger.error("mgmt control socket unrecoverable, sleeping 20s... (#{e.message})")
              sleep 20
            rescue => e
              BlueHydra.logger.error("Discovery loop crashed: #{e.message}")
              e.backtrace.each do |x|
                BlueHydra.logger.error("#{x}")
              end
              BlueHydra.send_event('blue_hydra',
              {key: 'blue_hydra_discovery_loop_error',
              title: 'Blue Hydras Discovery Loop Encountered An Error',
              message: "Discovery loop crashed: #{e.message}",
              severity: 'ERROR'
              })
              BlueHydra.logger.error("Sleeping 20s...")
              sleep 20
            end
          end

        rescue => e
          BlueHydra.logger.error("Discovery thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
          BlueHydra.send_event('blue_hydra',
          {key: 'blue_hydra_discovery_thread_error',
          title: 'Blue Hydras Discovery Thread Encountered An Error',
          message: "Discovery thread error: #{e.message}",
          severity: 'ERROR'
          })
        end
      end
    end

    # thread to manage the ubertooth device where available
    def start_ubertooth_thread
      BlueHydra.logger.info("Ubertooth thread starting")
      self.ubertooth_thread = Thread.new do
        begin
          loop do
            begin
              # Do a scan with ubertooth
              ubertooth_reset = BlueHydra::Command.execute3("ubertooth-util -U #{BlueHydra.config["ubertooth_index"]} -r")
              if ubertooth_reset[:stderr]
                BlueHydra.logger.error("Error with ubertooth-util -r...")
                ubertooth_reset[:stderr].split("\n").each do |ln|
                  BlueHydra.logger.error(ln)
                end
              end

              self.scanner_status[:ubertooth] = Time.now.to_i unless BlueHydra.daemon_mode
              ubertooth_output = BlueHydra::Command.execute3(@ubertooth_command,60)
              if ubertooth_output[:stderr]
                BlueHydra.logger.error("Error with ubertooth-{scan,rx}..")
                ubertooth_output[:stderr].split("\n").each do |ln|
                  BlueHydra.logger.error(ln)
                end
              else
                ubertooth_output[:stdout].each_line do |line|
                  if line =~ /^[\?:]{6}[0-9a-f:]{11}/i
                    address = line.scan(/^((\?\?:){2}([0-9a-f:]*))/i).flatten.first.gsub('?', '0')

                    # note that things here are being manually [array] wrapped
                    # so that they follow the data patterns set by the parser
                    result_queue.push({
                      address:      [address],
                      last_seen:    [Time.now.to_i],
                      classic_mode: [true]
                    })

                    push_to_queue(:classic, address)
                  end
                end
              end

              # scan with ubertooth for 40 seconds, sleep for 1, reset, repeat
              sleep 1
            end
          end
        end
      end
    end

    # thread to manage the CUI output where availalbe
    def start_cui_thread
      BlueHydra.logger.info("Command Line UI thread starting")
      self.cui_thread = Thread.new do
        cui  = BlueHydra::CliUserInterface.new(self)
        cui.help_message
        cui.cui_loop
      end
    end

    # thread to manage the CUI output where availalbe
    def start_api_thread
      BlueHydra.logger.info("API thread starting")
      self.api_thread = Thread.new do
        api  = BlueHydra::CliUserInterface.new(self)
        api.api_loop
      end
    end

    # helper method to push addresses intothe scan queues with a little
    # Whether a device may be scanned over the classic (BR/EDR) info path.
    #
    # Guards the classic info_scan_queue against devices whose classic_mode is
    # spurious/stale, so a futile classic connect (page timeout + hci_reset +
    # retry, which starves discovery) is never enqueued for a device that does
    # not actually speak BR/EDR:
    #
    #   1. A random/static LE address is not a BR/EDR public identity and can
    #      never be reached by classic paging - reject outright.
    #   2. An LE device flagged classic_mode but carrying NO positive classic
    #      evidence (no class-of-device from a BR/EDR inquiry, no classic
    #      features) has a stray/stale classic_mode - e.g. persisted from an
    #      older buggy run, or set by a transport-agnostic event. classic_mode
    #      only legitimately becomes true via a BR/EDR inquiry, which always
    #      carries class-of-device, so genuine classic and dual-mode devices
    #      still pass; only LE-only devices with a bogus flag are rejected.
    def classic_scannable?(device)
      return false if device.le_address_type.to_s =~ /Random/i
      return false if device.le_mode && !classic_evidence?(device)
      true
    end

    # True when a device carries positive evidence of a real BR/EDR presence:
    # class-of-device (only ever set from a classic inquiry result) or classic
    # features (only ever read over a classic connection). Used by
    # classic_scannable? to tell a genuine dual-mode device from an LE-only
    # device that was wrongly tagged classic_mode.
    def classic_evidence?(device)
      [device.classic_class,
       device.classic_major_class,
       device.classic_features_bitmap].any? do |v|
        v && (v.respond_to?(:empty?) ? !v.empty? : !v.to_s.empty?)
      end
    end

    # pre-processing
    def push_to_queue(mode, address, le_address_type = nil)
      case mode
      when :classic
        command = :info
        queue   = info_scan_queue
        # use uap_lap for tracking classic devices
        track_addr = address.split(":")[2,4].join(":")

        # do not send local adapter to be scanned y(>_<)y
        return if track_addr == BlueHydra::LOCAL_ADAPTER_ADDRESS.split(":")[2,4].join(":")
      when :le
        command = :leinfo
        # LE goes on its own queue, serviced during discovery (auto-connect
        # wants scanning on), separate from the classic queue which is drained
        # in a discovery-off phase.
        queue      = le_info_scan_queue
        track_addr = address

        # do not send local adapter to be scanned y(>_<)y
        return if address == BlueHydra::LOCAL_ADAPTER_ADDRESS
      end

      # only scan if the info scan rate timeframe has elapsed. info_scan_rate is
      # in SECONDS (matching its documented unit and default), applied directly -
      # no minutes conversion.
      self.query_history[track_addr] ||= {}
      last_info = self.query_history[track_addr][mode].to_i
      if BlueHydra.info_scan && (BlueHydra.config["info_scan_rate"].to_i > 0)
        if (Time.now.to_i - BlueHydra.config["info_scan_rate"].to_i) >= last_info
          queue.push({command: command, address: address, le_address_type: le_address_type})
          self.query_history[track_addr][mode] = Time.now.to_i
        end
      end
    end

    # thread responsible for chunking up btmon output to be parsed
    def start_chunker_thread
      BlueHydra.logger.info("Chunker thread starting")
      self.chunker_thread = Thread.new do
        loop do
          begin
            # handler, pass in chunk queue for data to be fed back out
            chunker = BlueHydra::Chunker.new(
              self.raw_queue,
              self.chunk_queue
            )
            chunker.chunk_it_up
          rescue => e
            BlueHydra.logger.error("Chunker thread #{e.message}")
            e.backtrace.each do |x|
              BlueHydra.logger.error("#{x}")
            end
            BlueHydra.logger.warn("Restarting Chunker...")
            BlueHydra.send_event('blue_hydra',
            {key: 'blue_hydra_chunker_error',
            title: 'Blue Hydras Chunker Thread Encountered An Error',
            message: "Chunker thread error: #{e.message}",
            severity: 'ERROR'
            })
          end
          sleep 1
        end
      end
    end

    # thread responsible for parsed chunked up btmon output
    def start_parser_thread
      BlueHydra.logger.info("Parser thread starting")
      self.parser_thread = Thread.new do
        begin

          scan_results = {}
          @rssi_data ||= {} if BlueHydra.signal_spitter

          # get the chunks and parse them, track history, update CUI and push
          # to data processing thread
          while chunk = chunk_queue.pop do
            p = BlueHydra::Parser.new(chunk.dup)
            p.parse

            attrs = p.attributes.dup

            address = (attrs[:address]||[]).uniq.first

            if address

              if !BlueHydra.daemon_mode || BlueHydra.file_api
                tracker = CliUserInterfaceTracker.new(self, chunk, attrs, address)
                tracker.update_cui_status
              end

              if scan_results[address]
                needs_push = false

                attrs.each do |k,v|

                  unless [:last_seen, :le_rssi, :classic_rssi].include? k
                    unless attrs[k] == scan_results[address][k]
                      scan_results[address][k] = v
                      needs_push = true
                    end
                  else
                    case
                    when k == :last_seen
                      current_time = attrs[k].sort.last
                      last_seen = scan_results[address][k].sort.last

                      # update this value no more than 1 x / minute to avoid
                      # flooding pulse with too much noise.
                      if (current_time - last_seen) > 60
                        attrs[k] = [current_time]
                        scan_results[address][k] = attrs[k]
                        needs_push = true
                      else
                        attrs[k] = [last_seen]
                      end

                    when [:le_rssi, :classic_rssi].include?(k)
                      current_time = attrs[k][0][:t]
                      last_seen_time = (scan_results[address][k][0][:t] rescue 0)

                      # if log_rssi is set log all values
                      if BlueHydra.config["rssi_log"] || BlueHydra.signal_spitter
                        attrs[k].each do |x|
                          # unix timestamp from btmon
                          ts = x[:t]

                          # '-90 dBm' ->  -90
                          rssi = x[:rssi].split(' ')[0].to_i

                          if BlueHydra.config["rssi_log"]
                            # LE / CL for classic mode
                            type = k.to_s.gsub('_rssi', '').upcase[0,2]

                            msg = [ts, type, address, rssi].join(' ')
                            BlueHydra.rssi_logger.info(msg)
                          end
                          if BlueHydra.signal_spitter
                            @rssi_data_mutex.synchronize {
                              @rssi_data[address] ||= []
                              @rssi_data[address] << {ts: ts, dbm: rssi}
                            }
                          end
                        end
                      end

                      # if aggressive_rssi is set send all rssis to pulse
                      # this should not be set where avoidable
                      # signal_spitter *should* make this irrelevant, remove?
                      if BlueHydra.config["aggressive_rssi"] && ( BlueHydra.pulse || BlueHydra.pulse_debug )
                        attrs[k].each do |x|
                          send_data = {
                            type:   "bluetooth-aggressive-rssi",
                            source: "blue-hydra",
                            version: BlueHydra::VERSION,
                            data: {}
                          }
                          send_data[:data][:status] = "online"
                          send_data[:data][:address] = address
                          send_data[:data][:sync_version] = BlueHydra::SYNC_VERSION
                          send_data[:data][k] = [x]

                          # create the json
                          json_msg = JSON.generate(send_data)
                          #send the json
                          BlueHydra::Pulse.do_send(json_msg)
                        end
                      end

                      # if aggressive_rssi is set send all rssis to stream builder too
                      if BlueHydra.config["aggressive_rssi"] && ( BlueHydra.stream_builder || BlueHydra.stream_builder_debug )
                        attrs[k].each do |x|
                          data = {
                            status:       "online",
                            address:      address,
                            sync_version: BlueHydra::SYNC_VERSION
                          }
                          data[k] = [x]
                          BlueHydra::StreamBuilder.sync_aggressive_rssi(data)
                        end
                      end

                      # update this value no more than 1 x / minute to avoid
                      # flooding pulse with too much noise.
                      if (current_time - last_seen_time) > 60
                        scan_results[address][k] = attrs[k]
                        needs_push = true
                      else
                        attrs.delete(k)
                      end
                    end
                  end
                end

                if needs_push
                  result_queue.push(attrs) unless self.stunned
                end
              else
                scan_results[address] = attrs
                result_queue.push(attrs) unless self.stunned
              end

            end

          end
        rescue => e
          BlueHydra.logger.error("Parser thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
          BlueHydra.send_event('blue_hydra',
          {key: 'blue_hydra_parser_thread_error',
          title: 'Blue Hydras Parser Thread Encountered An Error',
          message: "Parser thread error: #{e.message}",
          severity: 'ERROR'
          })
        end
      end
    end

    def start_signal_spitter_thread
      BlueHydra.logger.debug("RSSI API starting")
      self.signal_spitter_thread = Thread.new do
        begin
          loop do
            server = TCPServer.new("127.0.0.1", 1124)
            loop do
              Thread.start(server.accept) do |client|
                begin
                  magic_word = Timeout::timeout(1) do
                    client.gets.chomp
                  end
                rescue Timeout::Error
                  client.puts "ah ah ah, you didn't say the magic word"
                  client.close
                  return
                end
                if magic_word == 'bluetooth'
                  if @rssi_data
                    @rssi_data_mutex.synchronize {
                      client.puts JSON.generate(@rssi_data)
                    }
                  end
                end
                client.close
              end
            end
          end
        rescue => e
          BlueHydra.logger.error("RSSI API thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
          BlueHydra.send_event('blue_hydra',
          {key: 'blue_hydra_rssi_api_thread_error',
          title: 'Blue Hydras RSSI API Thread Encountered An Error',
          message: "RSSI API thread error: #{e.message}",
          severity: 'ERROR'
          })
        end
      end
    end

    def start_empty_spittoon_thread
      self.empty_spittoon_thread = Thread.new do
        BlueHydra.logger.debug("RSSI cleanup starting")
        begin
          signal_timeout = 120
          sleep signal_timeout #no point in cleaning until there is stuff to clean
          loop do
            sleep 1 #this is pretty agressive but it seems fine
            @rssi_data_mutex.synchronize {
              @rssi_data.each do |address, address_meta|
                @rssi_data[address].select{|d| d[:ts] > Time.now.to_i - signal_timeout} if @rssi_data[address]
              end
            }
          end
        rescue => e
          BlueHydra.logger.error("RSSI cleanup thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
          BlueHydra.send_event('blue_hydra',
          {key: 'blue_hydra_rssi_cleanup_thread_error',
          title: 'Blue Hydras RSSI Cleanup Thread Encountered An Error',
          message: "RSSI CLEANUP thread error: #{e.message}",
          severity: 'ERROR'
          })
        end
      end
    end

    # Recompute the processing speed (results/sec) once the sampling window has
    # elapsed. Dividing by the actual elapsed time (rather than a fixed value)
    # keeps the figure accurate no matter how long the window really was.
    #
    # This is called both from the busy inner loop, so it refreshes mid-burst,
    # and from the idle outer loop, so the rate falls to 0 during silence. It is
    # a no-op until the window elapses, so calling it from both places is safe
    # and never double counts.
    def update_processing_speed
      # 10 == processing speed sampling window in seconds
      now = Time.now.to_i
      return if (now - @processing_timer) < 10
      self.processing_speed = @processing_tracker.to_f / (now - @processing_timer)
      @processing_tracker   = 0
      @processing_timer     = now
    end

    def start_result_thread
      BlueHydra.logger.info("Result thread starting")
      self.result_thread = Thread.new do
        begin

          #debugging
          maxdepth              = 0
          self.processing_speed = 0
          @processing_tracker   = 0
          @processing_timer     = Time.now.to_i

          last_sync = Time.now

          # track the last time we swept the db for timed out devices so we can
          # throttle that sweep instead of running it on every queue drain
          last_offline_sweep = Time.now

          loop do
            # 1 day in seconds == 24 * 60 * 60 == 86400
            # daily sync
            if Time.now.to_i - 86400 >=  last_sync.to_i
              BlueHydra::Device.sync_all_to_pulse(last_sync)
              last_sync = Time.now
            end

            unless BlueHydra.config["file"]
              # if their last_seen value is > 7 minutes ago and not > 15 minutes ago
              #   l2ping them :  "l2ping -c 3 result[:address]"
              # constrain the last_seen window (and online status) in SQL rather
              # than loading every classic device and filtering in Ruby on the
              # hot path.
              BlueHydra::Device.all(
                classic_mode:    true,
                status:          "online",
                :last_seen.lt => (Time.now.to_i - (60 * 7)),
                :last_seen.gt => (Time.now.to_i - (60 * 15))
              ).each do |device|
                self.query_history[device.address] ||= {}
                if (Time.now.to_i - (60 * 7)) >= self.query_history[device.address][:l2ping].to_i

                  l2ping_queue.push({
                    command: :l2ping,
                    address: device.address
                  })

                  self.query_history[device.address][:l2ping] = Time.now.to_i
                end
              end
            end

            until result_queue.empty?
              if BlueHydra.daemon_mode
                queue_depth = result_queue.length
                if queue_depth > 250
                  if (maxdepth < queue_depth)
                    maxdepth = result_queue.length
                    BlueHydra.logger.warn("Popping off result queue. Max Depth: #{maxdepth} and rising")
                  else
                    BlueHydra.logger.warn("Popping off result queue. Max Depth: #{maxdepth} Currently: #{queue_depth}")
                  end
                end
              end

              result = result_queue.pop

              # refresh the speed mid-burst so the figure stays accurate while
              # results are actively flowing
              update_processing_speed
              @processing_tracker += 1

              unless BlueHydra.config["file"]
                # arbitrary low end cut off on slow processing to avoid stunning too often
                if self.processing_speed > 3 && result_queue.length >= self.processing_speed * 10
                  self.stunned = true
                elsif result_queue.length > 200
                  self.stunned = true
                end
              end

              if result[:address]
                device = BlueHydra::Device.update_or_create_from_result(result)

                unless BlueHydra.config["file"]
                  if device.le_mode
                    #do not info scan beacon type devices, they do not respond while in advertising mode
                    if device.company_type !~ /iBeacon/i && device.company !~ /Gimbal/i
                      # pass the parsed LE peer address type through so the
                      # discovery thread's auto-connect uses it (no DB read; the
                      # device object is already in memory here in the result
                      # thread)
                      push_to_queue(:le, device.address, device.le_address_type)
                    end
                  end

                  if device.classic_mode && classic_scannable?(device)
                    push_to_queue(:classic, device.address)
                  end
                end

              else
                BlueHydra.logger.warn("Device without address #{JSON.generate(result)}")
              end
            end

            # sweep for timed out devices periodically rather than on every
            # queue drain. Device timeouts are measured in minutes, so a 30s
            # sweep keeps statuses fresh while avoiding a constant full rescan
            # of the device table on the hot path.
            # 30 == sweep interval in seconds
            if Time.now.to_i - 30 >= last_offline_sweep.to_i
              BlueHydra::Device.mark_old_devices_offline
              last_offline_sweep = Time.now
            end

            self.stunned = false

            # also refresh during fully idle stretches (the inner loop is
            # skipped when the queue is empty) so the speed falls to 0 instead
            # of freezing at the last busy value
            update_processing_speed

            # only sleep if we still have nothing to do, seconds count
            sleep 1 if result_queue.empty?
          end

        rescue => e
          BlueHydra.logger.error("Result thread #{e.message}")
          e.backtrace.each do |x|
            BlueHydra.logger.error("#{x}")
          end
          BlueHydra.send_event('blue_hydra',
          {key: 'blue_hydra_result_thread_error',
          title: 'Blue Hydras Result Thread Encountered An Error',
          message: "Result thread #{e.message}",
          severity: 'ERROR'
          })
        end
      end

    end
  end
end
