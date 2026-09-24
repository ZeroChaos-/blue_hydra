require 'spec_helper'

# BlueHydra.send_event is the base notification dispatcher that fans an event
# out to Pulse and Stream Builder independently, keeping the two services
# decoupled from one another.
describe "BlueHydra.send_event" do
  after do
    BlueHydra.pulse = false
    BlueHydra.stream_builder = false
    BlueHydra.stream_builder_debug = false
  end

  it "forwards the event to Pulse when pulse is enabled" do
    BlueHydra.pulse = true
    expect(BlueHydra::Pulse).to receive(:send_event).with("k", { severity: "ERROR" })
    BlueHydra.send_event("k", { severity: "ERROR" })
  end

  it "does not forward to Pulse when pulse is disabled" do
    BlueHydra.pulse = false
    expect(BlueHydra::Pulse).not_to receive(:send_event)
    BlueHydra.send_event("k", { severity: "ERROR" })
  end

  it "sends a Stream Builder metric using the key as name and severity as a dimension when enabled" do
    BlueHydra.stream_builder = true
    expect(BlueHydra::StreamBuilder).to receive(:send_event).with(
      "blue_hydra_db_error",
      1,
      dimensions: [{ "name" => "severity", "value" => "FATAL" }]
    )
    BlueHydra.send_event("blue_hydra_db_error", { message: "boom", severity: "FATAL" })
  end

  # Every caller in the tree passes 'blue_hydra' as the positional argument and
  # puts the event identity in hash[:key] -- that is the shape Pulse expects, and
  # it is the only shape that actually occurs. Naming the metric after the
  # positional argument would collapse every event type in Blue Hydra into one
  # metric called "blue_hydra", leaving nothing to alarm on individually.
  it "names the metric after hash[:key] when the caller supplies one" do
    BlueHydra.stream_builder = true
    expect(BlueHydra::StreamBuilder).to receive(:send_event).with(
      "blue_hydra_transport_disabled",
      1,
      dimensions: [{ "name" => "severity", "value" => "WARN" }]
    )
    BlueHydra.send_event("blue_hydra", {
      key:      "blue_hydra_transport_disabled",
      title:    "Blue Hydra LE Disabled",
      message:  "hci0 has LE supported but disabled",
      severity: "WARN"
    })
  end

  it "distinguishes two event types sent under the same positional key" do
    BlueHydra.stream_builder = true
    names = []
    allow(BlueHydra::StreamBuilder).to receive(:send_event) { |name, _v, **_o| names << name }

    BlueHydra.send_event("blue_hydra", { key: "blue_hydra_db_error", severity: "FATAL" })
    BlueHydra.send_event("blue_hydra", { key: "blue_hydra_btmon_exited", severity: "ERROR" })

    expect(names).to eq(%w[blue_hydra_db_error blue_hydra_btmon_exited])
  end

  # Events that carry no :key at all still have to publish something.
  it "falls back to the positional key when the event has no hash[:key]" do
    BlueHydra.stream_builder = true
    expect(BlueHydra::StreamBuilder).to receive(:send_event).with(
      "blue_hydra",
      1,
      dimensions: [{ "name" => "severity", "value" => "INFO" }]
    )
    BlueHydra.send_event("blue_hydra", { severity: "INFO" })
  end

  # Dimensions are how an event says *what* it is about. The title and message
  # are prose and this path discards them, so anything a downstream consumer
  # needs to distinguish has to arrive as a dimension.
  it "appends the event's dimensions after severity" do
    BlueHydra.stream_builder = true
    expect(BlueHydra::StreamBuilder).to receive(:send_event).with(
      "blue_hydra_transport_unsupported",
      1,
      dimensions: [
        { "name" => "severity",  "value" => "WARN" },
        { "name" => "transport", "value" => "BREDR" }
      ]
    )
    BlueHydra.send_event("blue_hydra", {
      key:        "blue_hydra_transport_unsupported",
      severity:   "WARN",
      dimensions: [{ "name" => "transport", "value" => "BREDR" }]
    })
  end

  it "does not modify the dimensions array the caller passed in" do
    BlueHydra.stream_builder = true
    allow(BlueHydra::StreamBuilder).to receive(:send_event)
    caller_dimensions = [{ "name" => "transport", "value" => "LE" }]

    BlueHydra.send_event("blue_hydra", {
      key: "blue_hydra_transport_disabled", severity: "WARN", dimensions: caller_dimensions
    })

    expect(caller_dimensions).to eq([{ "name" => "transport", "value" => "LE" }])
  end

  it "does not send a Stream Builder metric when stream builder is disabled" do
    BlueHydra.stream_builder = false
    expect(BlueHydra::StreamBuilder).not_to receive(:send_event)
    BlueHydra.send_event("k", { severity: "ERROR" })
  end

  it "sends a Stream Builder metric when only stream_builder_debug is enabled" do
    BlueHydra.stream_builder_debug = true
    expect(BlueHydra::StreamBuilder).to receive(:send_event).with(
      "k",
      1,
      dimensions: [{ "name" => "severity", "value" => "ERROR" }]
    )
    BlueHydra.send_event("k", { severity: "ERROR" })
  end

  it "fans out to both services when both are enabled" do
    BlueHydra.pulse = true
    BlueHydra.stream_builder = true
    expect(BlueHydra::Pulse).to receive(:send_event).with("k", { severity: "WARN" })
    expect(BlueHydra::StreamBuilder).to receive(:send_event).with(
      "k",
      1,
      dimensions: [{ "name" => "severity", "value" => "WARN" }]
    )
    BlueHydra.send_event("k", { severity: "WARN" })
  end

  # Event keys are metric names downstream, so an inconsistent prefix is not
  # cosmetic: it surfaces in CloudWatch and in every alarm that references it.
  # Three keys used "bluehydra_" while the other 21 used "blue_hydra_"; this
  # keeps that from drifting back.
  it "names every event key with the blue_hydra_ prefix" do
    lib  = File.expand_path("../lib", __dir__)
    keys = Dir.glob(File.join(lib, "**", "*.rb")).flat_map do |file|
      File.read(file).scan(/key:\s*['"]([^'"]+)['"]/).flatten
    end.uniq

    expect(keys).not_to be_empty
    expect(keys.reject { |k| k.start_with?("blue_hydra_") }).to be_empty
  end
end
