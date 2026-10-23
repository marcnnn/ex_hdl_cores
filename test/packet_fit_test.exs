defmodule ExHdlCores.PacketFitTest do
  @moduledoc """
  `FIFO.packet/1` in the two places it is meant for: behind ex_net's MAC
  receiver (64 bit, 4 bit `tuser`, bit 0 = bad frame, valid with `tlast`)
  and in front of ex_aes67's depacketiser (64 bit, 96 bit metadata in
  `tuser` on the first beat, plus one error bit).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.{FIFO, Tb}

  @fields [:tdata, :tkeep, :tlast, :tuser]

  defp packets_gen,
    do:
      list_of(tuple({binary(min_length: 1, max_length: 90), member_of([:ok, :bad])}),
        min_length: 1,
        max_length: 8
      )

  # tuser per beat: `first` on the first beat, `last` on the last, noise-free zeros elsewhere
  defp with_user(pkts, first_fun, last_fun) do
    Enum.flat_map(pkts, fn {p, st} ->
      beats = Tb.beats(p, 8)
      n = length(beats)

      beats
      |> Enum.with_index(1)
      |> Enum.map(fn {b, i} ->
        user = if(i == 1, do: first_fun.(p), else: 0) ||| if(i == n, do: last_fun.(st), else: 0)
        Map.put(b, :tuser, user)
      end)
    end)
  end

  defp drive(mod, beats, vp, rp, seed) do
    Tb.drive(mod |> Sim.new() |> Sim.reset(),
      inputs: %{s_axis: beats},
      outputs: [:m_axis],
      valid: vp,
      ready: rp,
      seed: seed,
      fields: @fields,
      watch: [:drop_bad, :drop_full],
      idle: 40
    )
  end

  describe "ex_net MAC receive" do
    # tuser of the last beat: 0b0001 | status << 1 for bad frames (FCS error 1, receive error 2, ...)
    defp mac_status(:ok), do: 0b1000
    defp mac_status(:bad), do: 0b0011

    property "good frames pass whole with their status; bad ones vanish; tready stays high" do
      mod = FIFO.packet(data: 64, user: 4, err_bit: 0, depth: 128)
      assert Enum.find(mod.ports, &(&1.name == :s_axis_tready))

      check all(
              pkts <- packets_gen(),
              rp <- integer(20..100),
              seed <- integer(),
              max_runs: 25
            ) do
        beats = with_user(pkts, fn _ -> 0 end, &mac_status/1)
        r = drive(mod, beats, 100, rp, seed)

        good = for {p, :ok} <- pkts, do: p
        assert Tb.packets(r.out.m_axis, 8) == good

        # the status of a good frame arrives untouched on its last beat
        last_users = for %{tlast: 1, tuser: u} <- r.out.m_axis, do: u
        assert last_users == for({_, :ok} <- pkts, do: 0b1000)
        assert r.watched.drop_bad == Enum.count(pkts, &(elem(&1, 1) == :bad))
        assert r.watched.drop_full == 0
        # a MAC cannot be stopped: every beat was accepted at full rate
        assert r.consumed.s_axis == length(beats)
      end
    end

    test "tready is high at all times (the MAC has no backpressure input)" do
      mod = FIFO.packet(data: 64, user: 4, depth: 16)
      sim = mod |> Sim.new() |> Sim.reset()
      beats = with_user([{:binary.copy(<<7>>, 200), :ok}], fn _ -> 0 end, &mac_status/1)

      Enum.reduce(beats, sim, fn b, sim ->
        sim =
          Sim.poke(sim, %{
            s_axis_tvalid: 1,
            s_axis_tdata: b.tdata,
            s_axis_tkeep: b.tkeep,
            s_axis_tlast: b.tlast,
            s_axis_tuser: b.tuser,
            m_axis_tready: 0
          })

        assert Sim.peek(sim, :s_axis_tready) == 1
        Sim.step(sim)
      end)
    end
  end

  describe "ex_aes67 depacketiser input" do
    @meta_bits 96
    defp meta(p), do: :erlang.phash2(p, 1 <<< 32) * 0x1_0000_0001_0000_0001 &&& (1 <<< 96) - 1

    property "metadata on the first beat is delivered with each good packet" do
      mod = FIFO.packet(data: 64, user: @meta_bits + 1, err_bit: @meta_bits, depth: 256)

      check all(
              pkts <- packets_gen(),
              rp <- integer(20..100),
              seed <- integer(),
              max_runs: 12
            ) do
        beats =
          with_user(pkts, &meta/1, fn st -> if st == :bad, do: 1 <<< @meta_bits, else: 0 end)

        r = drive(mod, beats, 90, rp, seed)

        good = for {p, :ok} <- pkts, do: p
        assert Tb.packets(r.out.m_axis, 8) == good

        firsts =
          for {%{tuser: u}, true} <- Enum.zip(r.out.m_axis, first_flags(r.out.m_axis)), do: u

        assert firsts == Enum.map(good, &meta/1)
      end
    end

    # a beat is first when the previous one had tlast (or it is the first beat)
    defp first_flags(beats), do: [true | Enum.map(Enum.drop(beats, -1), &(&1.tlast == 1))]

    test "a burst larger than the FIFO drops whole packets and counts them" do
      mod = FIFO.packet(data: 64, user: @meta_bits + 1, err_bit: @meta_bits, depth: 32)
      pkts = for i <- 1..6, do: {:binary.copy(<<i>>, 100), :ok}
      beats = with_user(pkts, &meta/1, fn _ -> 0 end)
      r = drive(mod, beats, 100, 10, 3)
      out = Tb.packets(r.out.m_axis, 8)
      assert out != []
      assert Enum.all?(out, &(&1 in Enum.map(pkts, fn {p, _} -> p end)))
      assert length(out) + r.watched.drop_full == length(pkts)
    end
  end

  @tag :verilator
  @tag timeout: 300_000
  test "both shapes co-simulate" do
    for opts <- [
          [data: 64, user: 4, err_bit: 0, depth: 16],
          [data: 64, user: 97, err_bit: 96, depth: 16]
        ] do
      m = FIFO.packet(opts)

      Cosim.assert_equivalent(
        m,
        Tb.random_stimulus(m, 300, 5,
          bias: %{s_axis_tvalid: 80, s_axis_tlast: 25, m_axis_tready: 60}
        )
      )
    end
  end
end
