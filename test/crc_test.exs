defmodule ExHdlCores.CRCTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.{CRC, Tb}

  describe "reference model" do
    test "catalogue check values" do
      for name <- CRC.presets(), do: assert(CRC.compute(name, "123456789") == CRC.check(name))
    end

    property "CRC-32 equals :erlang.crc32/1" do
      check all(bin <- binary(max_length: 100)) do
        assert CRC.compute(:crc32, bin) == :erlang.crc32(bin)
      end
    end

    test "the matrices are the bit-serial step" do
      c = CRC.params(:crc16_kermit)
      %{state: sm, data: dm} = CRC.matrices(c, 2)
      par = fn v -> v |> Integer.digits(2) |> Enum.sum() |> rem(2) end

      for {s, d} <- [{0x1234, 0xBEEF}, {0xFFFF, 0}, {0, 0x8001}] do
        want = CRC.step_word(c, s, d, 2)

        got =
          for j <- 0..15, reduce: 0 do
            acc ->
              bit = Bitwise.bxor(par.(s &&& Enum.at(sm, j)), par.(d &&& Enum.at(dm, j)))
              acc ||| bit <<< j
          end

        assert got == want
      end
    end
  end

  # Runs frames through the module: `bytes` per word, random gaps, optional
  # clear on the first word or a separate clear cycle.
  defp run_frames(mod, bytes, frames, seed) do
    :rand.seed(:exsss, {seed, 5, 6})
    sim = mod |> Sim.new() |> Sim.reset()
    keep? = Enum.any?(mod.ports, &(&1.name == :keep))

    {crcs, _} =
      Enum.map_reduce(frames, sim, fn frame, sim ->
        words = Tb.beats(frame, bytes)

        sim =
          Enum.with_index(words)
          |> Enum.reduce(sim, fn {w, i}, sim ->
            sim =
              if :rand.uniform(3) == 1,
                do:
                  sim
                  |> Sim.poke(%{valid: 0, clear: 0, data: :rand.uniform(256) - 1})
                  |> Sim.step(),
                else: sim

            pokes = %{data: w.tdata, valid: 1, clear: if(i == 0, do: 1, else: 0)}
            pokes = if keep?, do: Map.put(pokes, :keep, w.tkeep), else: pokes
            sim |> Sim.poke(pokes) |> Sim.step()
          end)

        sim = Sim.poke(sim, %{valid: 0, clear: 0})
        {Sim.peek(sim, :crc), sim}
      end)

    crcs
  end

  describe "hardware" do
    test "CRC-32 over 1, 4 and 8 bytes per cycle matches :erlang.crc32/1" do
      frames = [
        "123456789",
        "The quick brown fox jumps over the lazy dog",
        <<0>>,
        <<255, 255, 255>>
      ]

      for bytes <- [1, 4, 8] do
        mod = CRC.build(:crc32, bytes: bytes)
        assert run_frames(mod, bytes, frames, bytes) == Enum.map(frames, &:erlang.crc32/1)
      end
    end

    test "catalogue check values in hardware, 1 and 3 bytes per cycle" do
      for name <- CRC.presets(), bytes <- [1, 3] do
        assert [CRC.check(name)] ==
                 run_frames(CRC.build(name, bytes: bytes), bytes, ["123456789"], 1),
               "#{name} with #{bytes} bytes"
      end
    end

    test "CRC-32C and CRC-16/CCITT-FALSE check values" do
      assert [0xE3069283] == run_frames(CRC.build(:crc32c, bytes: 4), 4, ["123456789"], 1)
      assert [0x29B1] == run_frames(CRC.build(:crc16_ccitt_false, bytes: 2), 2, ["123456789"], 1)
    end

    test "keep: false needs whole words" do
      mod = CRC.build(:crc32, bytes: 4, keep: false)
      refute Enum.any?(mod.ports, &(&1.name == :keep))
      assert [:erlang.crc32("abcdefgh")] == run_frames(mod, 4, ["abcdefgh"], 1)
    end

    test "clear without valid restarts" do
      sim = CRC.build(:crc32) |> Sim.new() |> Sim.reset()

      sim =
        sim
        |> Sim.poke(%{data: 7, valid: 1})
        |> Sim.step()
        |> Sim.poke(%{valid: 0, clear: 1})
        |> Sim.step()

      assert Sim.poke(sim, :clear, 0) |> Sim.peek(:crc) == :erlang.crc32("")
    end

    property "random widths, polynomials, reflection and bus widths match the model" do
      check all(
              w <- integer(3..40),
              poly <- integer(1..((1 <<< w) - 1)),
              init <- integer(0..((1 <<< w) - 1)),
              xorout <- integer(0..((1 <<< w) - 1)),
              refin <- boolean(),
              refout <- boolean(),
              bytes <- integer(1..5),
              frames <-
                list_of(binary(min_length: 1, max_length: 30), min_length: 1, max_length: 3),
              seed <- integer(),
              max_runs: 40
            ) do
        p = [width: w, poly: poly, init: init, xorout: xorout, refin: refin, refout: refout]
        mod = CRC.build(p, bytes: bytes)
        assert run_frames(mod, bytes, frames, seed) == Enum.map(frames, &CRC.compute(p, &1))
      end
    end

    @tag :verilator
    @tag timeout: 300_000
    test "co-simulates" do
      for {p, bytes} <- [{:crc32, 4}, {:crc16_kermit, 3}, {:crc5_usb, 1}] do
        m = CRC.build(p, bytes: bytes)

        Cosim.assert_equivalent(
          m,
          Tb.random_stimulus(m, 300, bytes, bias: %{valid: 70, clear: 10})
        )
      end
    end
  end
end
