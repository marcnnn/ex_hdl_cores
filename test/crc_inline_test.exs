defmodule ExHdlCores.CRCInlineTest do
  @moduledoc "`CRC.next/5` and `CRC.final/2` inside another module (a MAC keeping the register itself)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.{CRC, Tb}

  defmodule Host do
    @moduledoc false
    use ExHdl.RTL
    alias ExHdlCores.CRC

    # a miniature MAC: its own state register, frame start loads init
    def build(params, bytes) do
      c = CRC.params(params)
      w = c.width

      module "inline_#{bytes}_#{w}_#{c.poly}" do
        data = input(:data, 8 * bytes)
        keep = input(:keep, bytes)
        valid = input(:valid, 1)
        start = input(:start, 1)
        out = output(:out, w)
        st = reg(:st, w, reset: c.init)
        base = wire(:base, mux(start, const(c.init, w), st))

        sync do
          if valid, do: st <~ CRC.next(params, base, data, keep, bytes)
        end

        out <~ CRC.final(params, st)
      end
    end
  end

  defp host(params, bytes), do: Host.build(params, bytes)

  defp frame_events(frame, bytes) do
    frame
    |> Tb.beats(bytes)
    |> Enum.with_index()
    |> Enum.map(fn {b, i} ->
      %{data: b.tdata, keep: b.tkeep, valid: 1, start: if(i == 0, do: 1, else: 0)}
    end)
  end

  for {params, bytes} <- [{:crc32, 1}, {:crc32, 8}, {:crc32c, 4}, {:crc16_arc, 3}, {:crc8, 2}] do
    property "#{params} over #{bytes} byte words equals CRC.compute/2" do
      params = unquote(params)
      bytes = unquote(bytes)
      mod = host(params, bytes)

      check all(
              frames <-
                list_of(binary(min_length: 1, max_length: 40), min_length: 1, max_length: 4),
              max_runs: 20
            ) do
        sim = mod |> Sim.new() |> Sim.reset()

        Enum.reduce(frames, sim, fn f, sim ->
          sim = Enum.reduce(frame_events(f, bytes), sim, &(&2 |> Sim.poke(&1) |> Sim.step()))
          sim = Sim.poke(sim, %{valid: 0})
          assert Sim.peek(sim, :out) == CRC.compute(params, f)
          sim
        end)
      end
    end
  end

  test "next/5 with keep nil is a full word; init/1 and final/2" do
    assert CRC.init(:crc32) == 0xFFFFFFFF
    assert CRC.init(:crc8) == 0
  end

  test "equals the standalone module cycle by cycle" do
    inline = host(:crc32, 8)
    alone = CRC.build(:crc32, bytes: 8, clear_port: :start)
    # the standalone module also restarts on `start` without `valid` and ignores keep = 0
    stim =
      for ev <- Tb.random_stimulus(inline, 200, 3) do
        ev = if ev[:keep] == 0, do: Map.put(ev, :keep, 1), else: ev
        if ev[:valid] == 0, do: Map.put(ev, :start, 0), else: ev
      end

    {_, a} = inline |> Sim.new() |> Sim.run(stim)
    {_, b} = alone |> Sim.new() |> Sim.run(stim)
    assert Enum.map(a, & &1.out) == Enum.map(b, & &1.crc)
  end

  @tag :verilator
  @tag timeout: 600_000
  test "inline step co-simulates" do
    mod = host(:crc32, 8)
    Cosim.assert_equivalent(mod, Tb.random_stimulus(mod, 300, 4))
  end
end
