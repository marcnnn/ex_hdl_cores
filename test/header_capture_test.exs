defmodule ExHdlCores.HeaderCaptureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.{AxisDriver, HeaderCapture, Tb}

  property "stream passes unchanged; hdr, hdr_len, hdr_valid of the last packet" do
    for {header, bytes} <- [{14, 8}, {16, 4}, {5, 1}, {64, 8}, {3, 8}] do
      mod = HeaderCapture.build(header: header, data: 8 * bytes)

      check all(
              pkts <-
                list_of(binary(min_length: 1, max_length: 90), min_length: 1, max_length: 4),
              {vp, rp, seed} <- {integer(20..100), integer(20..100), integer(0..1000)},
              max_runs: 15
            ) do
        r =
          AxisDriver.run(mod,
            frames: %{s_axis: pkts},
            sinks: [:m_axis],
            valid: vp,
            ready: rp,
            seed: seed
          )

        assert r.frames.m_axis == pkts
        outs = Sim.outputs(r.sim)
        {hdr, len} = HeaderCapture.ref(List.last(pkts), header)
        assert {outs.hdr, outs.hdr_len, outs.hdr_valid} == {hdr, len, 1}
      end
    end
  end

  test "hdr_valid timing: rises after the header, falls on the next packet's first beat" do
    mod = HeaderCapture.build(header: 12, data: 32)
    sim = mod |> Sim.new() |> Sim.reset() |> Sim.poke(%{m_axis_tready: 1})

    beat = fn sim, d, k, l ->
      sim = Sim.poke(sim, %{s_axis_tvalid: 1, s_axis_tdata: d, s_axis_tkeep: k, s_axis_tlast: l})
      {Sim.outputs(sim), Sim.step(sim)}
    end

    {o, sim} = beat.(sim, 0x04030201, 15, 0)
    assert {o.hdr_valid, o.hdr_start} == {0, 0}
    {o, sim} = beat.(sim, 0x08070605, 15, 0)
    assert {o.hdr_valid, o.hdr_start} == {0, 1}
    {o, sim} = beat.(sim, 0x0C0B0A09, 15, 0)
    assert o.hdr_valid == 0
    {o, sim} = beat.(sim, 0xFFFFFFFF, 15, 1)
    assert {o.hdr_valid, o.hdr_len, o.hdr} == {1, 12, 0x0C0B0A090807060504030201}
    # next packet, one beat of 2 bytes
    {o, sim} = beat.(sim, 0xFFFF1234, 3, 1)
    assert o.hdr_valid == 1
    {o, _} = beat.(sim, 0, 0, 0)
    assert {o.hdr_valid, o.hdr_len, o.hdr} == {1, 2, 0x1234}
  end

  test "back pressure: nothing is captured while tready is low" do
    mod = HeaderCapture.build(header: 8, data: 32)
    sim = mod |> Sim.new() |> Sim.reset()

    sim =
      Sim.poke(sim, %{
        s_axis_tvalid: 1,
        s_axis_tdata: 0x11223344,
        s_axis_tkeep: 15,
        s_axis_tlast: 1
      })

    sim = Sim.step(sim, 3)
    o = Sim.outputs(sim)
    assert {o.hdr_len, o.hdr_valid, o.s_axis_tready} == {0, 0, 0}
  end

  @tag :verilator
  @tag timeout: 600_000
  test "co-simulates, and the Verilator session driver sees the same frames" do
    mod = HeaderCapture.build(header: 20, data: 64)
    Cosim.assert_equivalent(mod, Tb.random_stimulus(mod, 400, 9))
    pkts = for n <- [1, 7, 8, 9, 20, 41], do: :binary.copy(<<n>>, n)
    a = AxisDriver.run(mod, frames: %{s_axis: pkts}, sinks: [:m_axis], seed: 4)

    b =
      AxisDriver.run(mod, frames: %{s_axis: pkts}, sinks: [:m_axis], seed: 4, backend: :verilator)

    assert a.frames == b.frames and b.frames.m_axis == pkts
    assert a.cycles == b.cycles
  end
end
