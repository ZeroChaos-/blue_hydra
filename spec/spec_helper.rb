# encoding: UTF-8
require 'rubygems'
require 'rspec'
require 'simplecov'
SimpleCov.start

$:.unshift(File.dirname(File.expand_path('../../lib/blue_hydra.rb',__FILE__)))

ENV["BLUE_HYDRA"] = "test"

require 'blue_hydra'

BlueHydra.daemon_mode = true
BlueHydra.pulse = false

# Stand-in for BlueHydra.chunk_logger that makes writing the real
# blue_hydra_chunk.log a test failure.
#
# Chunk-log writes only happen with chunker_debug enabled (chunker.rb, on
# multi-address and zero-address chunks). A spec that needs to exercise that
# path must install its own chunk_logger double and assert against it; nothing
# may reach the real file, which otherwise accumulates in the package root and
# gets baked into the container image.
#
# Two layers, because neither is sufficient alone:
#   * writes raise, so an in-band write fails the example that caused it
#   * writes are also recorded, because the chunker is usually driven on a
#     throwaway Thread (see ai_spec's `drain`, which kills the thread without
#     ever joining it) where a raise is silently swallowed. after(:suite) then
#     fails the run on anything recorded.
class ChunkLogGuard
  ChunkLogWritten = Class.new(StandardError)

  class << self
    attr_accessor :baseline

    def violations
      @violations ||= []
    end

    def size
      File.exist?(BlueHydra::CHUNK_LOGFILE) ? File.size(BlueHydra::CHUNK_LOGFILE) : 0
    end
  end

  # The owning example is captured at construction rather than read at write
  # time: RSpec.current_example is thread-local, so a write from a chunker thread
  # would otherwise be reported with no attribution at all.
  def initialize(example = nil)
    @example = example
  end

  # every Logger write method the chunker could reach
  [:info, :debug, :warn, :error, :fatal, :unknown, :add, :<<].each do |method|
    define_method(method) do |*_args|
      message = "#{source} -> BlueHydra.chunk_logger.#{method}: stub chunk_logger " \
                "with a double instead of writing #{BlueHydra::CHUNK_LOGFILE}"

      ChunkLogGuard.violations << message
      raise ChunkLogWritten, message
    end
  end

  # harmless configuration calls the real Logger accepts
  def level=(_level); end
  def formatter=(_formatter); end

  private

  def source
    example = @example
    example ||= RSpec.current_example if RSpec.respond_to?(:current_example)
    example ? example.full_description : "(outside an example)"
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = [:should, :expect]
  end

  config.before(:each) do |example|
    allow(BlueHydra).to receive(:chunk_logger).and_return(ChunkLogGuard.new(example))
  end

  # Baseline is taken here, not at require time, on purpose: requiring
  # blue_hydra above already ran Logger.new(CHUNK_LOGFILE), which creates the
  # file and writes a "# Logfile created on ..." header. That is not a chunker
  # write, so it belongs in the baseline.
  config.before(:suite) do
    ChunkLogGuard.baseline = ChunkLogGuard.size
  end

  # Ordering-independent check, unlike an ordinary example: the file is measured
  # once around the whole run. The size check is a backstop for anything that
  # bypasses BlueHydra.chunk_logger and writes the path directly.
  config.after(:suite) do
    problems = ChunkLogGuard.violations.uniq
    grew     = ChunkLogGuard.size - ChunkLogGuard.baseline
    problems << "#{BlueHydra::CHUNK_LOGFILE} grew by #{grew} bytes" if grew > 0

    unless problems.empty?
      raise ChunkLogGuard::ChunkLogWritten,
            "the chunk log must not be written during the suite:\n  - " +
            problems.join("\n  - ")
    end
  end
end

