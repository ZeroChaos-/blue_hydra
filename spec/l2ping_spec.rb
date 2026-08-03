require 'spec_helper'

describe BlueHydra::L2Ping do
  let(:probe) { BlueHydra::L2Ping.new(0, connect_timeout: 1) }
  let(:sock)  { instance_double("Socket") }

  before do
    # inject the fake socket and default the lifecycle methods
    allow(probe).to receive(:open_socket).and_return(sock)
    allow(sock).to receive(:closed?).and_return(false)
    allow(sock).to receive(:close)
    # guard: the probe must never send echo bytes
    allow(sock).to receive(:write)
    allow(sock).to receive(:send)
  end

  # helper: an IO::WaitWritable-flavored exception like connect_nonblock raises
  def wait_writable_error
    err = Errno::EINPROGRESS.new
    err.extend(IO::WaitWritable)
    err
  end

  it "returns :reachable when the connect completes immediately" do
    allow(sock).to receive(:connect_nonblock).and_return(0)
    expect(probe.reach?("AA:BB:CC:DD:EE:FF")).to eq(:reachable)
  end

  it "treats connection refused as :reachable (ACL came up, PSM refused)" do
    allow(sock).to receive(:connect_nonblock).and_raise(Errno::ECONNREFUSED)
    expect(probe.reach?("AA:BB:CC:DD:EE:FF")).to eq(:reachable)
  end

  it "treats host down as :unreachable" do
    allow(sock).to receive(:connect_nonblock).and_raise(Errno::EHOSTDOWN)
    expect(probe.reach?("AA:BB:CC:DD:EE:FF")).to eq(:unreachable)
  end

  it "treats a page timeout (ETIMEDOUT) as :unreachable" do
    allow(sock).to receive(:connect_nonblock).and_raise(Errno::ETIMEDOUT)
    expect(probe.reach?("AA:BB:CC:DD:EE:FF")).to eq(:unreachable)
  end

  it "completes a non-blocking connect: writable then EISCONN => :reachable" do
    calls = 0
    allow(sock).to receive(:connect_nonblock) do
      calls += 1
      calls == 1 ? raise(wait_writable_error) : raise(Errno::EISCONN)
    end
    allow(probe).to receive(:wait_writable).and_return(true)
    expect(probe.reach?("AA:BB:CC:DD:EE:FF")).to eq(:reachable)
  end

  it "returns :unreachable when the connect never becomes writable (timeout)" do
    allow(sock).to receive(:connect_nonblock).and_raise(wait_writable_error)
    allow(probe).to receive(:wait_writable).and_return(false)
    expect(probe.reach?("AA:BB:CC:DD:EE:FF")).to eq(:unreachable)
  end

  it "returns :error on an unexpected socket error" do
    allow(sock).to receive(:connect_nonblock).and_raise(Errno::EACCES)
    expect(probe.reach?("AA:BB:CC:DD:EE:FF")).to eq(:error)
  end

  it "always closes the socket" do
    allow(sock).to receive(:connect_nonblock).and_return(0)
    probe.reach?("AA:BB:CC:DD:EE:FF")
    expect(sock).to have_received(:close)
  end

  it "closes the socket even when the probe errors" do
    allow(sock).to receive(:connect_nonblock).and_raise(Errno::EACCES)
    probe.reach?("AA:BB:CC:DD:EE:FF")
    expect(sock).to have_received(:close)
  end

  it "never sends echo bytes (no write/send on the socket)" do
    allow(sock).to receive(:connect_nonblock).and_return(0)
    probe.reach?("AA:BB:CC:DD:EE:FF")
    expect(sock).not_to have_received(:write)
    expect(sock).not_to have_received(:send)
  end
end
