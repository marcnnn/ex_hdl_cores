defmodule ExHdlCores.ArbiterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.{Arbiter, Tb}
  alias ExHdlCores.Arbiter.Model

  # the combinational arbiters have no clock and no reset
  defp rst(mod, v), do: if(Enum.any?(mod.ports, &(&1.name == :rst_n)), do: %{rst_n: v}, else: %{})

  defp compare(mod, kind, n, hold, events) do
    events = Enum.map(events, &Map.merge(&1, rst(mod, 1)))
    {_, out} = mod |> Sim.new() |> Sim.run([rst(mod, 0), rst(mod, 0)] ++ events)

    {exp, _} =
      Enum.map_reduce(
        [{0, 0}, {0, 0}] ++ Enum.map(events, &{&1.req, &1.adv}),
        Model.new(kind, n, hold),
        fn
          {req, adv}, m ->
            {m, out} = Model.step(m, req, adv)
            {out, m}
        end
      )

    # during reset (first two events) the registers are at reset, as in the model
    assert Enum.drop(out, 2) |> Enum.map(&Map.take(&1, [:grant, :idx, :valid])) ==
             Enum.drop(exp, 2)
  end

  for kind <- [:fixed, :rr], hold <- [:none, :packet] do
    property "#{kind} (hold #{hold}) matches the model" do
      check all(
              n <- integer(1..7),
              events <-
                list_of(
                  fixed_map(%{req: integer(0..127), adv: integer(0..1)}),
                  min_length: 5,
                  max_length: 60
                ),
              max_runs: 60
            ) do
        mask = Bitwise.bsl(1, n) - 1
        events = Enum.map(events, &%{&1 | req: Bitwise.band(&1.req, mask)})

        mod =
          apply(Arbiter, unquote(if kind == :fixed, do: :fixed, else: :round_robin), [
            n,
            [hold: unquote(hold)]
          ])

        compare(mod, unquote(kind), n, unquote(hold), events)
      end
    end
  end

  test "round robin is fair with all requesting" do
    mod = Arbiter.round_robin(4)
    stim = [%{rst_n: 0}] ++ List.duplicate(%{rst_n: 1, req: 15, adv: 1}, 8)
    {_, out} = mod |> Sim.new() |> Sim.run(stim)
    assert out |> Enum.drop(1) |> Enum.map(& &1.idx) == [0, 1, 2, 3, 0, 1, 2, 3]
  end

  test "fixed priority prefers requester 0" do
    {_, out} =
      Arbiter.fixed(3)
      |> Sim.new()
      |> Sim.run([%{req: 0b110, adv: 1}, %{req: 0b111}, %{req: 0}])

    assert Enum.map(out, & &1.grant) == [0b010, 0b001, 0]
  end

  test "packet mode holds the grant until adv" do
    {_, out} =
      Arbiter.round_robin(3, hold: :packet)
      |> Sim.new()
      |> Sim.run([
        %{rst_n: 0},
        %{rst_n: 1, req: 0b100, adv: 0},
        %{req: 0b111},
        %{req: 0b011},
        %{req: 0b011, adv: 1},
        %{req: 0b011, adv: 0}
      ])

    assert Enum.map(out, & &1.grant) == [0, 0b100, 0b100, 0b100, 0b100, 0b001]
  end

  @tag :verilator
  @tag timeout: 300_000
  test "co-simulates" do
    for {m, i} <-
          Enum.with_index([
            Arbiter.fixed(5),
            Arbiter.round_robin(5),
            Arbiter.round_robin(6, hold: :packet)
          ]) do
      Cosim.assert_equivalent(m, Tb.random_stimulus(m, 400, i, bias: %{adv: 30}))
    end
  end
end
