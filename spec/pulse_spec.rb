require 'spec_helper'

describe BlueHydra::Pulse do
  describe ".send_event" do
    after { BlueHydra.pulse = false }

    it "does not call Stream Builder (Pulse and Stream Builder are decoupled)" do
      expect(BlueHydra::StreamBuilder).not_to receive(:send_event)
      BlueHydra::Pulse.send_event("blue_hydra_test_event", { severity: "ERROR" })
    end

    it "returns false when pulse is enabled" do
      BlueHydra.pulse = true
      expect(BlueHydra::Pulse.send_event("blue_hydra_test_event", { severity: "ERROR" })).to eq(false)
    end

    it "returns nil when pulse is disabled" do
      BlueHydra.pulse = false
      expect(BlueHydra::Pulse.send_event("blue_hydra_test_event", { severity: "ERROR" })).to be_nil
    end
  end
end
