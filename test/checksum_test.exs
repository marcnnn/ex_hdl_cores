defmodule ExHdlCores.ChecksumTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  use ExHdl.RTL
  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.{Checksum, Tb}

  # Feeds frames word by word with random gaps; returns the sum after each frame.
  defp run_frames(mod, bytes, frames, seed) do
    :rand.seed(:exsss, {seed, 7, 8})
    sim = mod |> Sim.new() |> Sim.reset()
    latency = if String.ends_with?(mod.name, "_p1"), do: 1, else: 0

    {sums, _} =
      Enum.map_reduce(frames, sim, fn frame, sim ->
        sim =
          frame
          |> Tb.beats(bytes)
          |> Enum.with_index()
          |> Enum.reduce(sim, fn {w, i}, sim ->
            sim =
              if :rand.uniform(3) == 1,
                do:
                  sim
                  |> Sim.poke(%{valid: 0, clear: 0, data: :rand.uniform(256) - 1})
                  |> Sim.step(),
                else: sim

            sim
            |> Sim.poke(%{
              data: w.tdata,
              keep: w.tkeep,
              valid: 1,
              clear: if(i == 0, do: 1, else: 0)
            })
            |> Sim.step()
          end)

        sim = sim |> Sim.poke(%{valid: 0, clear: 0}) |> Sim.step(latency)
        {{Sim.peek(sim, :sum), Sim.peek(sim, :csum)}, sim}
      end)

    sums
  end

  describe "reference" do
    test "RFC 1071 example" do
      bin = <<0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7>>
      assert Checksum.sum(bin) == 0xDDF2
      assert Checksum.csum(bin) == 0x220D
    end

    test "an IPv4 header with its checksum sums to 0xFFFF" do
      hdr =
        <<0x45, 0, 0, 0x73, 0, 0, 0x40, 0, 0x40, 0x11, 0xB8, 0x61, 0xC0, 0xA8, 0, 1, 0xC0, 0xA8,
          0, 0xC7>>

      assert Checksum.sum(hdr) == 0xFFFF
      assert Checksum.csum(hdr) == 0
    end

    test "odd lengths pad on the right; all zero stays 0" do
      assert Checksum.sum(<<0xAB>>) == 0xAB00
      assert Checksum.sum(<<0, 0, 0>>) == 0
      assert Checksum.sum(<<0xFF, 0xFF, 0xFF, 0xFF>>) == 0xFFFF
    end
  end

  describe "hardware" do
    for bytes <- [2, 4, 8, 64], pipe <- [0, 1] do
      property "#{bytes} bytes per cycle, pipeline #{pipe}: equals the reference" do
        bytes = unquote(bytes)
        mod = Checksum.build(bytes: bytes, pipeline: unquote(pipe))

        check all(
                frames <-
                  list_of(binary(min_length: 1, max_length: 200), min_length: 1, max_length: 4),
                seed <- integer(),
                max_runs: 20
              ) do
          want = for f <- frames, do: {Checksum.sum(f), Checksum.csum(f)}
          assert run_frames(mod, bytes, frames, seed) == want
        end
      end
    end

    test "all ones and carries" do
      mod = Checksum.build(bytes: 8)

      frames = [
        :binary.copy(<<255>>, 64),
        :binary.copy(<<255>>, 63),
        <<0, 0, 0, 0>>,
        <<1, 0, 0xFF, 0xFE>>
      ]

      want = for f <- frames, do: {Checksum.sum(f), Checksum.csum(f)}
      assert run_frames(mod, 8, frames, 1) == want
    end

    test "keep: false takes whole words" do
      mod = Checksum.build(bytes: 4, keep: false)
      refute Enum.any?(mod.ports, &(&1.name == :keep))
      sim = mod |> Sim.new() |> Sim.reset()
      sim = sim |> Sim.poke(%{data: 0x04030201, valid: 1, clear: 1}) |> Sim.step()
      sim = sim |> Sim.poke(%{valid: 0, clear: 0})
      assert Sim.peek(sim, :sum) == Checksum.sum(<<1, 2, 3, 4>>)
    end

    test "the window helper inside a module sums a masked header" do
      m =
        module "window_top" do
          d = input(:d, 64)
          k = input(:k, 8)
          s = output(:s, 16)
          s <~ Checksum.window(d, k, 8)
        end

      sim = Sim.new(m)
      pkt = <<0x45, 0x00, 0x12, 0x34, 0xAB, 0xCD, 0x00, 0x00>>
      <<d::little-64>> = pkt
      assert sim |> Sim.poke(%{d: d, k: 0xFF}) |> Sim.peek(:s) == Checksum.sum(pkt)

      assert sim |> Sim.poke(%{d: d, k: 0x0F}) |> Sim.peek(:s) ==
               Checksum.sum(binary_part(pkt, 0, 4))
    end

    @tag :verilator
    @tag timeout: 300_000
    test "co-simulates" do
      for {bytes, pipe} <- [{4, 0}, {16, 1}] do
        m = Checksum.build(bytes: bytes, pipeline: pipe)

        Cosim.assert_equivalent(
          m,
          Tb.random_stimulus(m, 300, bytes, bias: %{valid: 70, clear: 10})
        )
      end
    end
  end
end
