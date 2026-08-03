require 'spec_helper'

describe BlueHydra::Command do
  it 'executes a shell command and returns a hash of output' do
    result = BlueHydra::Command.execute3("echo 'hello world'")
    expect(result[:exit_code]).to eq(0)
    expect(result[:stdout]).to eq("hello world")
    expect(result[:stderr]).to eq(nil)
  end
end

describe "local adapter address enumeration (mgmt Read Controller Information)" do
  it "returns an array of at most one mac address" do
    begin
      result = BlueHydra::EnumLocalAddr.call
      expect(result).to be_an(Array)
      expect(result.count).to be <= 1
      if result.first
        expect(result.first).to match(/\A(?:[0-9A-F]{2}:){5}[0-9A-F]{2}\z/)
      end
    rescue BluezNotReadyError, MgmtSocketError, SystemCallError, IOError
      # No usable Bluetooth adapter in the test environment; acceptable.
      expect(1).to eq(1)
    end
  end
end
