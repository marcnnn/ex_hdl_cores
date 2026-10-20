defmodule ExHdlCores.UtilTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.{Tb, Util}
  alias ExHdlCores.Util.Model

  # Runs `stim` after two reset events and compares every model output.
  defp check(mod, stim, expected) do
    rst = fn v -> if Enum.any?(mod.ports, &(&1.name == :rst_n)), do: %{rst_n: v}, else: %{} end
    stim = Enum.map(stim, &Map.merge(&1, rst.(1)))
    {_, out} = mod |> Sim.new() |> Sim.run([rst.(0), rst.(0)] ++ stim)
    keys = expected |> hd() |> Map.keys()
    assert out |> Enum.drop(2) |> Enum.map(&Map.take(&1, keys)) == expected
  end

  defp bits(pct),
    do: StreamData.frequency([{pct, StreamData.constant(1)}, {100 - pct, StreamData.constant(0)}])

  defp stimulus(fields, len \\ 150) do
    fields
    |> Map.new(fn {k, pct} -> {k, bits(pct)} end)
    |> StreamData.fixed_map()
    |> StreamData.list_of(min_length: 5, max_length: len)
  end

  property "counter (up, down, max) matches the model" do
    check all(
            width <- integer(2..6),
            max <- integer(1..((1 <<< width) - 1)),
            down <- boolean(),
            stim <- stimulus(%{en: 60, clear: 5}, 120),
            max_runs: 50
          ) do
      opts = [max: max, down: down]
      check(Util.counter(width, opts), stim, Model.counter(width, opts, stim))
    end
  end

  property "prescaler matches the model" do
    check all(div <- integer(1..9), stim <- stimulus(%{en: 60}), max_runs: 30) do
      check(Util.prescaler(div), stim, Model.prescaler(div, stim))
    end
  end

  property "pulse stretcher matches the model" do
    check all(cycles <- integer(1..9), stim <- stimulus(%{pulse: 10}), max_runs: 30) do
      check(Util.pulse_stretcher(cycles), stim, Model.pulse_stretcher(cycles, stim))
    end
  end

  property "timer (one-shot and periodic) matches the model" do
    check all(
            periodic <- boolean(),
            stim <-
              list_of(
                fixed_map(%{
                  start: bits(8),
                  stop: bits(3),
                  value: integer(0..9)
                }),
                min_length: 10,
                max_length: 150
              ),
            max_runs: 50
          ) do
      mod = Util.timer(4, periodic: periodic)
      stim = if periodic, do: stim, else: Enum.map(stim, &Map.delete(&1, :stop))

      check(
        mod,
        stim,
        Model.timer([periodic: periodic], Enum.map(stim, &Map.put_new(&1, :stop, 0)))
      )
    end
  end

  property "debouncer matches the model" do
    check all(
            cycles <- integer(1..6),
            stages <- integer(2..3),
            init <- integer(0..1),
            stim <- stimulus(%{in: 50}, 200),
            max_runs: 30
          ) do
      stim = Enum.map(stim, &%{in: &1.in})
      opts = [stages: stages, init: init]
      check(Util.debouncer(cycles, opts), stim, Model.debouncer(cycles, opts, stim))
    end
  end

  test "debouncer ignores glitches and follows a stable input" do
    stim = List.duplicate(%{in: 0}, 4) ++ [%{in: 1}, %{in: 0}] ++ List.duplicate(%{in: 1}, 12)

    {_, out} =
      Util.debouncer(5)
      |> Sim.new()
      |> Sim.run([%{rst_n: 0} | Enum.map(stim, &Map.put(&1, :rst_n, 1))])

    outs = Enum.map(out, & &1.out)
    assert Enum.take(outs, 8) == [0, 0, 0, 0, 0, 0, 0, 0]
    assert List.last(outs) == 1
    assert Enum.sum(Enum.map(out, & &1.rise)) == 1
  end

  test "timer: value cycles between start and done" do
    stim = [%{start: 1, value: 3}] ++ List.duplicate(%{start: 0}, 6)
    {_, out} = Util.timer(4) |> Sim.new() |> Sim.run([%{rst_n: 0}, %{rst_n: 1} | stim])

    assert out |> Enum.drop(2) |> Enum.map(&{&1.busy, &1.done}) ==
             [{0, 0}, {1, 0}, {1, 0}, {1, 0}, {0, 1}, {0, 0}, {0, 0}]
  end

  test "periodic timer: done every value + 1 cycles, stop cancels the reload" do
    stim =
      [%{rst_n: 0}, %{rst_n: 1, start: 1, value: 3, stop: 0}] ++
        List.duplicate(%{start: 0}, 8) ++ [%{stop: 1}, %{stop: 0}] ++ List.duplicate(%{}, 6)

    {_, out} = Util.timer(4, periodic: true) |> Sim.new() |> Sim.run(stim)
    dones = out |> Enum.map(& &1.done) |> Enum.with_index() |> Enum.filter(&(elem(&1, 0) == 1))
    assert Enum.map(dones, &elem(&1, 1)) == [5, 9]
    assert out |> Enum.drop(11) |> Enum.all?(&(&1.busy == 0 and &1.done == 0))
  end

  test "pulse stretcher: out is high for exactly `cycles` cycles" do
    stim = [%{pulse: 1}] ++ List.duplicate(%{pulse: 0}, 6)
    {_, out} = Util.pulse_stretcher(3) |> Sim.new() |> Sim.run([%{rst_n: 0}, %{rst_n: 1} | stim])
    assert out |> Enum.drop(2) |> Enum.map(& &1.out) == [0, 1, 1, 1, 0, 0, 0]
  end

  property "blinker and heartbeat match the model" do
    check all(
            period <- integer(2..12),
            on <- integer(1..period),
            step <- integer(1..5),
            n <- integer(20..120),
            max_runs: 20
          ) do
      stim = List.duplicate(%{}, n)
      check(Util.blinker(period, on), stim, Model.blinker(period, on, stim))
      check(Util.heartbeat(step), stim, Model.heartbeat(step, [], stim))
    end
  end

  test "blinker duty and heartbeat pattern" do
    stim = List.duplicate(%{}, 20)
    {_, out} = Util.blinker(5, 2) |> Sim.new() |> Sim.run([%{rst_n: 0}, %{rst_n: 1} | stim])

    assert out |> Enum.drop(1) |> Enum.take(10) |> Enum.map(& &1.out) == [
             1,
             1,
             0,
             0,
             0,
             1,
             1,
             0,
             0,
             0
           ]

    {_, out} = Util.heartbeat(2) |> Sim.new() |> Sim.run([%{rst_n: 0}, %{rst_n: 1} | stim])
    assert out |> Enum.drop(1) |> Enum.take(8) |> Enum.map(& &1.out) == [1, 1, 1, 1, 0, 0, 0, 0]
  end

  @tag :verilator
  @tag timeout: 300_000
  test "co-simulates" do
    mods = [
      Util.counter(6, max: 40),
      Util.counter(4, down: true),
      Util.prescaler(5),
      Util.timer(5, periodic: true),
      Util.timer(5),
      Util.pulse_stretcher(7),
      Util.debouncer(4),
      Util.blinker(7, 3),
      Util.heartbeat(3)
    ]

    for {m, i} <- Enum.with_index(mods) do
      Cosim.assert_equivalent(
        m,
        Tb.random_stimulus(m, 300, i, bias: %{start: 10, clear: 5, stop: 5, pulse: 15})
      )
    end
  end
end
