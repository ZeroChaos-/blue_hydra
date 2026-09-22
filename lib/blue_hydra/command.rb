module BlueHydra::Command
  # How long a child gets to exit on TERM before we escalate to KILL, and how
  # long we then wait on the KILL.
  #
  # Both short and both bounded, because this runs on the shutdown path: a child
  # we failed to reap is a smaller problem than a shutdown that hangs waiting for
  # one. A USB radio can sit in an uninterruptible ioctl, where even KILL does
  # not land promptly, so the second wait has a ceiling too.
  CHILD_TERM_GRACE = 2
  CHILD_KILL_GRACE = 1

  # execute a command using Open3
  #
  # == Parameters
  #   command ::
  #     the command to execute
  #
  # == Returns
  #   Hash containing :stdout, :stderr, :exit_code from the command
  def execute3(command, timeout=false, timeout_signal="SIGKILL")
    stdin = stdout = stderr = thread = nil

    begin
      BlueHydra.logger.debug("Executing Command: #{command}")
      output = {}
      if timeout
        stop_time = Time.now.to_i + timeout.to_i
      end

      stdin, stdout, stderr, thread = Open3.popen3(command)
      stdin.close

      if timeout
        until Time.now.to_i > stop_time || thread.status == false
          sleep 0.1
        end

        # Only when we actually ran out of time. The loop above exits on EITHER
        # condition, so logging unconditionally reported a timeout for every
        # command that finished normally.
        if thread.status != false
          BlueHydra.logger.debug("Timeout on command: #{command}")

          begin
            Process.kill(timeout_signal, thread.pid)
          rescue Errno::ESRCH
            BlueHydra.logger.warn("Command: #{command} exited unnaturally.")
            BlueHydra.send_event("blue_hydra",
            {key: 'blue_hydra_command_error',
            title: 'Blue Hydra subprocess exited unnaturally',
            message: "Command: #{command} exited unnaturally.",
            severity: 'WARN'
            })
          end
        end
      end

      if (out = stdout.read.chomp) != ""
        output[:stdout]    = out
      end

      if (err = stderr.read.chomp) != ""
        output[:stderr]    = err
      end

      output[:exit_code] = thread.value.exitstatus

      output
    rescue Errno::ENOMEM, NoMemoryError
      BlueHydra.logger.fatal("System couldn't allocate enough memory to run an external command.")
      BlueHydra.send_event('blue_hydra',
      {
        key: "bluehydra_oom",
        title: "BlueHydra couldnt allocate enough memory to run external command. Sensor OOM.",
        message: "BlueHydra couldnt allocate enough memory to run external command. Sensor OOM.",
        severity: "FATAL"
      })
      exit 1
    ensure
      # The child is ours to clean up on EVERY exit path, not just the ones we
      # thought of. An ensure here is what makes that true, and it is the only
      # place it can be true: the leak this closes is Runner#stop calling
      # Thread#kill on the discovery and ubertooth threads, which unwinds them
      # wherever they happen to be - typically blocked in stdout.read above. A
      # killed Ruby thread still runs its ensure blocks (verified), so this is
      # reached; the timeout branch's Process.kill is not, because the thread
      # never gets back there.
      #
      # Left unhandled that meant a stray child holding the hardware after we
      # exited: hcitool info on the controller we were power-cycling, and worse,
      # ubertooth-rx/-scan on the USB radio for up to its 60s timeout. In a
      # container that restarts blue_hydra, the replacement then finds the device
      # busy. Same reasoning and same shape as BtmonHandler#reap.
      terminate_child(thread, command)
      close_streams(stdin, stdout, stderr)
    end
  end

  # Stop and reap +thread+'s child if it is still running.
  #
  # A no-op on the normal path: execute3 has already called thread.value by then,
  # so the waiter thread has finished and #alive? is false. This only does work
  # when a command was abandoned, which is worth a log line - it says a command's
  # output was thrown away.
  def terminate_child(thread, command)
    return unless thread && thread.alive?

    BlueHydra.logger.debug("Abandoning command, terminating child: #{command}")

    return if signal_child(thread, "TERM") && thread.join(CHILD_TERM_GRACE)

    # Ignored the TERM, or wedged somewhere it cannot be delivered. Escalate
    # rather than let shutdown wait on it.
    signal_child(thread, "KILL")
    thread.join(CHILD_KILL_GRACE)
  end

  # Signal the child, returning false if it is already gone (nothing to wait for).
  #
  # Reaping is left to Open3's waiter thread - the caller joins that rather than
  # calling Process.wait itself, which would race the waiter for the same pid and
  # lose with ECHILD.
  def signal_child(thread, signal)
    Process.kill(signal, thread.pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    # already exited, or not ours to signal
    false
  end

  # Close the command's pipes.
  #
  # Also a real fix rather than tidiness: execute3 closed stdin and left stdout
  # and stderr to the garbage collector, so every invocation held two descriptors
  # until a GC pass happened to reclaim them. Non-deterministic, and this runs
  # once per classic device per info-scan cycle.
  def close_streams(*streams)
    streams.each do |io|
      begin
        io.close if io && !io.closed?
      rescue IOError
        # already closed underneath us; nothing to do
      end
    end
  end

  module_function :execute3, :terminate_child, :signal_child, :close_streams
end
