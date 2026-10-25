defmodule ExHdlCores.CommaAlignerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.{CommaAligner, Tb}

  # K28.5 (both disparities) alternating with D21.5; no other 5-bit run of equal bits
  @k_neg "0011111010"
  @k_pos "1100000101"
  @d21_5 "1010101010"

  defp pattern(n),
    do: Enum.map_join(1..n, fn i -> if(rem(i, 2) == 1, do: @k_neg, else: @k_pos) <> @d21_5 end)

  # the bit stream cut into 10-bit chunks after dropping `off` leading bits
  defp chunks(bits, off, n) do
    bits
    |> binary_part(off, 10 * n)
    |> :binary.bin_to_list()
    |> Enum.chunk_every(10)
    |> Enum.map(fn c -> c |> List.to_string() |> String.to_integer(2) end)
  end

  defp run(mod, chunks, lock \\ 0) do
    sim = mod |> Sim.new() |> Sim.reset()

    {outs, _} =
      Enum.map_reduce(chunks, sim, fn c, sim ->
        sim = Sim.poke(sim, %{code: c, lock: lock})
        {Sim.outputs(sim), Sim.step(sim)}
      end)

    outs
  end

  property "any bit offset: the stream comes out in code groups, K28.5 first" do
    mod = CommaAligner.build()
    groups = for s <- [@k_neg, @k_pos, @d21_5], do: String.to_integer(s, 2)

    check all(off <- integer(0..9), max_runs: 10) do
      outs = run(mod, chunks(pattern(12), off, 11))
      tail = outs |> Enum.drop(8) |> Enum.map(& &1.aligned)
      assert Enum.all?(tail, &(&1 in groups))
      assert Enum.any?(tail, &(&1 in [0b0011111010, 0b1100000101]))
    end
  end

  test "lock freezes the offset" do
    mod = CommaAligner.build()
    # locked from the start: shift stays 0 although commas pass by
    assert Enum.all?(run(mod, chunks(pattern(12), 3, 11), 1), &(&1.shift == 0))
    # unlocked it follows the comma
    assert List.last(run(mod, chunks(pattern(12), 3, 11), 0)).shift != 0
  end

  property "BEAM simulation equals ref/2 for random chunks, 10 and 8 bit words" do
    for {opts, w} <- [{[], 10}, {[width: 8, comma_len: 5, commas: [0b00111]], 8}] do
      mod = CommaAligner.build(opts)

      check all(
              cs <-
                list_of(tuple({integer(0..((1 <<< w) - 1)), integer(0..3)}),
                  min_length: 10,
                  max_length: 60
                ),
              max_runs: 30
            ) do
        cs = Enum.map(cs, fn {c, l} -> {c, if(l == 0, do: 1, else: 0)} end)
        sim = mod |> Sim.new() |> Sim.reset()

        {outs, _} =
          Enum.map_reduce(cs, sim, fn {c, l}, sim ->
            sim = Sim.poke(sim, %{code: c, lock: l})
            o = Sim.outputs(sim)
            {{o.aligned, o.shift}, Sim.step(sim)}
          end)

        assert outs == CommaAligner.ref(cs, opts)
      end
    end
  end

  @tag :verilator
  @tag timeout: 600_000
  test "co-simulates (10 and 8 bit)" do
    for {opts, i} <- Enum.with_index([[], [width: 8, comma_len: 5, commas: [0b00111]]]) do
      mod = CommaAligner.build(opts)
      Cosim.assert_equivalent(mod, Tb.random_stimulus(mod, 500, i))
    end
  end
end
