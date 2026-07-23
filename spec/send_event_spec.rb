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
end
