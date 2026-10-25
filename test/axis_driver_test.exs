defmodule ExHdlCores.AxisDriverTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.RTL.Sim
  alias ExHdlCores.{AXIS, AxisDriver}

  test "beats and packets are inverse" do
    for bytes <- [1, 4, 8], pkt <- [<<1>>, "abcdefghijk", :binary.copy("x", 16)] do
      assert AxisDriver.packets(AxisDriver.beats(pkt, bytes), bytes) == [pkt]
    end
  end

  property "run/2: frames through a skid buffer under random backpressure, extra fields kept" do
    mod = AXIS.skid(data: 32, user: 2)

    check all(
            pkts <- list_of(binary(min_length: 1, max_length: 30), min_length: 1, max_length: 5),
            {vp, rp, seed} <- {integer(10..100), integer(10..100), integer(0..500)},
            max_runs: 30
          ) do
      r =
        AxisDriver.run(mod,
          frames: %{s_axis: Enum.map(pkts, &{&1, %{tuser: 2}})},
          sinks: [:m_axis],
          valid: vp,
          ready: rp,
          seed: seed
        )

      assert r.frames.m_axis == pkts
      assert Enum.all?(r.out.m_axis, &(&1.tuser == 2))
      assert r.consumed.s_axis == length(Enum.flat_map(pkts, &AxisDriver.beats(&1, 4)))
    end
  end

  test "a block that drops tvalid while stalled is caught" do
    mod = bad_source()

    assert_raise RuntimeError, ~r/changed or tvalid dropped/, fn ->
      AxisDriver.run(mod, frames: %{}, sinks: [:m_axis], ready: 0, bytes: 1, fields: [:tdata])
    end
  end

  test "max_cycles raises unless timeout_ok" do
    mod = AXIS.skid(data: 8)

    opts = [frames: %{s_axis: ["abc"]}, sinks: [:m_axis], ready: 0, max_cycles: 20, idle: 100]
    assert_raise RuntimeError, ~r/max_cycles/, fn -> AxisDriver.run(mod, opts) end
    r = AxisDriver.run(mod, [timeout_ok: true] ++ opts)
    assert r.frames.m_axis == []
  end

  test "drive/2 on a Sim with pre: hook for other inputs" do
    mod = AXIS.skid(data: 8, kind: :forward)
    sim = mod |> Sim.new() |> Sim.reset()
    beats = AxisDriver.beats("hello", 1)

    r =
      AxisDriver.drive(sim,
        inputs: %{s_axis: beats},
        outputs: [:m_axis],
        pre: fn sim, _ -> sim end,
        valid: 100,
        ready: 100
      )

    assert AxisDriver.packets(r.out.m_axis, 1) == ["hello"]
  end

  @tag :verilator
  @tag timeout: 600_000
  test "Verilator session gives the same beats as the BEAM simulator, cycle for cycle" do
    mod = AXIS.skid(data: 32, user: 2)
    pkts = for n <- [1, 3, 4, 5, 17, 40], do: :binary.copy(<<n>>, n)

    for seed <- 1..3 do
      opts = [frames: %{s_axis: pkts}, sinks: [:m_axis], valid: 55, ready: 45, seed: seed]
      a = AxisDriver.run(mod, opts)
      b = AxisDriver.run(mod, [backend: :verilator] ++ opts)
      assert b.frames.m_axis == pkts
      assert {a.out, a.cycles} == {b.out, b.cycles}
    end
  end

  defmodule Bad do
    @moduledoc false
    use ExHdl.RTL

    # master port whose tvalid and tdata toggle regardless of tready
    def build do
      module "bad_source" do
        m = master(:m_axis, ExHdlCores.AXIS.iface(data: 8, keep: false, last: false))
        t = reg(:t, 1, reset: 0)

        sync do
          t <~ not t
        end

        m.tvalid <~ t
        m.tdata <~ cat([const(0, 7), t])
      end
    end
  end

  defp bad_source, do: Bad.build()
end
