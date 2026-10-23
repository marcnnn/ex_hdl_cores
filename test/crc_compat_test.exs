defmodule ExHdlCores.CRCCompatTest do
  @moduledoc """
  `ExHdlCores.CRC` configured as ex_net's `ExNet.RTL.CRC32` (`crc32_8` /
  `crc32_64`): same ports, same cycle behaviour. The model is the contract
  of ex_net's own test (reflected register, init 0xFFFFFFFF, outputs show
  the register one cycle after the word), written here independently.
  """
  # Verilator builds of the 64-bit CRC take over a minute on a loaded host.
  @moduletag timeout: 600_000
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.CRC

  @residue 0xDEBB20E3

  # reflected CRC-32 register, one bit at a time
  defp step_bit(r, bit) do
    sh = r >>> 1
    if (bxor(r, bit) &&& 1) == 1, do: bxor(sh, 0xEDB88320), else: sh
  end

  defp step_bytes(r, data, n) do
    for i <- 0..(8 * n - 1), reduce: r, do: (r -> step_bit(r, data >>> i &&& 1))
  end

  defp compat(bytes) do
    CRC.build(:crc32,
      bytes: bytes,
      clear_port: :init,
      state: true,
      residue: true,
      zero_keep: :one_byte,
      name: "crc32_#{8 * bytes}"
    )
  end

  defp cycles(bytes) do
    gen =
      tuple({
        integer(0..((1 <<< (8 * bytes)) - 1)),
        integer(1..bytes),
        boolean(),
        boolean()
      })

    list_of(gen, min_length: 5, max_length: 80)
  end

  defp b(true), do: 1
  defp b(false), do: 0

  defp events(cs, bytes) do
    for {d, n, v, i} <- cs do
      base = %{data: d, valid: b(v), init: b(i)}
      if bytes > 1, do: Map.put(base, :keep, (1 <<< n) - 1), else: base
    end
  end

  defp expected(cs) do
    {rev, _} =
      Enum.reduce(cs, {[], 0xFFFFFFFF}, fn {d, n, v, i}, {acc, s} ->
        out = %{state: s, crc: bxor(s, 0xFFFFFFFF), ok: b(s == @residue)}
        s0 = if i, do: 0xFFFFFFFF, else: s
        s1 = if v, do: step_bytes(s0, d &&& (1 <<< (8 * n)) - 1, n), else: s0
        {[out | acc], s1}
      end)

    Enum.reverse(rev)
  end

  defp run(mod, events) do
    sim = mod |> Sim.new() |> Sim.reset()

    {outs, _} =
      Enum.map_reduce(events, sim, fn ev, sim ->
        sim = Sim.poke(sim, ev)
        {Map.take(Sim.outputs(sim), [:state, :crc, :ok]), Sim.step(sim)}
      end)

    outs
  end

  test "residue of CRC-32" do
    assert CRC.residue(:crc32) == @residue
  end

  test "ports are ex_net's" do
    for {bytes, ins} <- [{1, [:data, :valid, :init]}, {8, [:data, :keep, :valid, :init]}] do
      m = compat(bytes)
      assert m.name == "crc32_#{8 * bytes}"

      names = fn dir -> for(p <- m.ports, p.dir == dir and p.role == :data, do: p.name) end
      assert Enum.sort(names.(:input)) == Enum.sort(ins)
      assert Enum.sort(names.(:output)) == [:crc, :ok, :state]
    end
  end

  for bytes <- [1, 8] do
    describe "#{8 * bytes}-bit" do
      @bytes bytes

      property "matches ex_net's model cycle by cycle, keep 0 included" do
        mod = compat(@bytes)

        check all(cs <- cycles(@bytes), max_runs: 25) do
          assert run(mod, events(cs, @bytes)) == expected(cs)
        end
      end

      test "a frame with its FCS ends in the residue" do
        mod = compat(@bytes)
        frame = for i <- 1..61, into: <<>>, do: <<rem(i * 37, 256)>>
        wire = frame <> <<:erlang.crc32(frame)::little-32>>

        evs =
          wire
          |> :binary.bin_to_list()
          |> Enum.chunk_every(@bytes)
          |> Enum.with_index()
          |> Enum.map(fn {ch, i} ->
            d = ch |> Enum.with_index() |> Enum.reduce(0, fn {x, k}, a -> a ||| x <<< (8 * k) end)
            ev = %{data: d, valid: 1, init: b(i == 0)}
            if @bytes > 1, do: Map.put(ev, :keep, (1 <<< length(ch)) - 1), else: ev
          end)

        out = run(mod, evs ++ [%{valid: 0, init: 0}]) |> List.last()
        assert out.ok == 1
        assert out.state == @residue
      end

      @tag :verilator
      test "co-simulates" do
        mod = compat(@bytes)
        [cs] = Enum.take(resize(cycles(@bytes), 80), 1)

        evs =
          for {ev, i} <- Enum.with_index(events(cs, @bytes)), do: Map.put(ev, :rst_n, b(i > 1))

        Cosim.assert_equivalent(mod, evs)
      end
    end
  end
end
