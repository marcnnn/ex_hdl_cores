defmodule ExHdlCores.AXISTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.{AXIS, Tb}

  defp packets_gen(n \\ 5),
    do: list_of(binary(min_length: 1, max_length: 19), min_length: 1, max_length: n)

  defp reset(mod), do: mod |> Sim.new() |> Sim.reset()

  defp rates, do: {integer(20..100), integer(20..100), integer(0..1000)}

  describe "skid buffer and register slice" do
    for kind <- [:skid, :forward] do
      property "#{kind}: every beat once, in order, protocol kept" do
        mod = AXIS.skid(data: 32, user: 2, kind: unquote(kind))

        check all(
                pkts <- packets_gen(),
                {vp, rp, seed} <- rates(),
                max_runs: 40
              ) do
          beats = Enum.flat_map(pkts, &Tb.beats(&1, 4, %{tuser: 1}))
          fields = [:tdata, :tkeep, :tlast, :tuser]

          r =
            Tb.drive(reset(mod),
              inputs: %{s_axis: beats},
              outputs: [:m_axis],
              valid: vp,
              ready: rp,
              seed: seed,
              fields: fields
            )

          assert r.out.m_axis == beats
        end
      end

      test "#{kind}: full throughput" do
        mod = AXIS.skid(kind: unquote(kind))
        beats = for i <- 1..50, do: %{tdata: i, tkeep: 15, tlast: 0}

        r =
          Tb.drive(reset(mod),
            inputs: %{s_axis: beats},
            outputs: [:m_axis],
            valid: 100,
            ready: 100,
            idle: 5
          )

        assert r.out.m_axis == beats
        assert r.cycles <= 50 + 1 + 5
      end
    end
  end

  describe "width converters" do
    property "upsize: packets keep their bytes, partial last word, user ORed, id of last beat" do
      check all(
              ib <- integer(1..4),
              k <- integer(2..4),
              pkts <- packets_gen(),
              {vp, rp, seed} <- rates(),
              max_runs: 40
            ) do
        ob = ib * k
        mod = AXIS.upsize(in_bytes: ib, out_bytes: ob, user: 3, id: 4)
        :rand.seed(:exsss, {seed, 1, 1})

        beats =
          Enum.flat_map(pkts, fn p ->
            p
            |> Tb.beats(ib)
            |> Enum.map(
              &Map.merge(&1, %{tuser: :rand.uniform(8) - 1, tid: :rand.uniform(16) - 1})
            )
          end)

        r =
          Tb.drive(reset(mod),
            inputs: %{s_axis: beats},
            outputs: [:m_axis],
            valid: vp,
            ready: rp,
            seed: seed,
            fields: [:tdata, :tkeep, :tlast, :tuser, :tid]
          )

        # model: words of k input beats, a packet's last word may be short
        want =
          beats
          |> Enum.chunk_while(
            [],
            fn b, acc ->
              if b.tlast == 1, do: {:cont, Enum.reverse([b | acc]), []}, else: {:cont, [b | acc]}
            end,
            fn _ -> {:cont, []} end
          )
          |> Enum.flat_map(fn pkt ->
            pkt
            |> Enum.chunk_every(k)
            |> Enum.map(fn word ->
              %{
                tdata:
                  word
                  |> Enum.with_index()
                  |> Enum.reduce(0, fn {b, i}, a -> a ||| b.tdata <<< (8 * ib * i) end),
                tkeep:
                  word
                  |> Enum.with_index()
                  |> Enum.reduce(0, fn {b, i}, a -> a ||| b.tkeep <<< (ib * i) end),
                tlast: List.last(word).tlast,
                tuser: Enum.reduce(word, 0, &(&1.tuser ||| &2)),
                tid: List.last(word).tid
              }
            end)
          end)

        assert r.out.m_axis == want
        assert Tb.packets(r.out.m_axis, ob) == pkts
      end
    end

    property "downsize: packets keep their bytes, user repeated" do
      check all(
              ob <- integer(1..4),
              k <- integer(2..4),
              pkts <- packets_gen(),
              {vp, rp, seed} <- rates(),
              max_runs: 40
            ) do
        ib = ob * k
        mod = AXIS.downsize(in_bytes: ib, out_bytes: ob, user: 3)
        user = :rand.uniform(7)
        beats = Enum.flat_map(pkts, &Tb.beats(&1, ib, %{tuser: user}))

        r =
          Tb.drive(reset(mod),
            inputs: %{s_axis: beats},
            outputs: [:m_axis],
            valid: vp,
            ready: rp,
            seed: seed,
            fields: [:tdata, :tkeep, :tlast, :tuser]
          )

        assert r.out.m_axis == Enum.flat_map(pkts, &Tb.beats(&1, ob, %{tuser: user}))
      end
    end

    test "convert picks the direction; odd ratios are rejected" do
      assert AXIS.convert(in_bytes: 2, out_bytes: 8).name =~ "upsize"
      assert AXIS.convert(in_bytes: 8, out_bytes: 2).name =~ "downsize"
      assert AXIS.convert(in_bytes: 4, out_bytes: 4).name =~ "skid"

      assert_raise ArgumentError, ~r/integer ratio/, fn ->
        AXIS.convert(in_bytes: 3, out_bytes: 8)
      end
    end

    test "downsize runs at full rate" do
      mod = AXIS.downsize(in_bytes: 8, out_bytes: 2)
      beats = for i <- 1..20, do: %{tdata: i, tkeep: 255, tlast: if(i == 20, do: 1, else: 0)}

      r =
        Tb.drive(reset(mod),
          inputs: %{s_axis: beats},
          outputs: [:m_axis],
          valid: 100,
          ready: 100,
          idle: 5
        )

      assert length(r.out.m_axis) == 80
      assert r.cycles <= 80 + 2 + 5
    end

    test "upsize accepts one beat per cycle" do
      mod = AXIS.upsize(in_bytes: 2, out_bytes: 8)
      beats = for i <- 1..40, do: %{tdata: i, tkeep: 3, tlast: if(i == 40, do: 1, else: 0)}

      r =
        Tb.drive(reset(mod),
          inputs: %{s_axis: beats},
          outputs: [:m_axis],
          valid: 100,
          ready: 100,
          idle: 5
        )

      assert length(r.out.m_axis) == 10
      assert r.cycles <= 40 + 2 + 5
    end
  end

  # Packets tagged with source and sequence number.
  defp tagged(pkts, src),
    do: pkts |> Enum.with_index() |> Enum.map(fn {p, i} -> <<src, i>> <> p end)

  describe "merge" do
    property "packet mode: whole packets, each input's order kept" do
      check all(
              n <- integer(1..4),
              arbiter <- member_of([:round_robin, :fixed]),
              inputs <- list_of(packets_gen(4), length: n),
              {vp, rp, seed} <- rates(),
              max_runs: 40
            ) do
        mod = AXIS.merge(n, data: 32, arbiter: arbiter)
        ins = for {pk, i} <- Enum.with_index(inputs), do: tagged(pk, i)

        feed =
          for {pk, i} <- Enum.with_index(ins),
              into: %{},
              do: {:"s#{i}_axis", Enum.flat_map(pk, &Tb.beats(&1, 4))}

        r =
          Tb.drive(reset(mod), inputs: feed, outputs: [:m_axis], valid: vp, ready: rp, seed: seed)

        out = Tb.packets(r.out.m_axis, 4)

        # no interleaving: beats of a packet are contiguous, so the packets parse back exactly
        assert Enum.sort(out) == Enum.sort(List.flatten(ins))

        for pk <- ins do
          assert Enum.filter(out, &(&1 in pk)) == pk
        end
      end
    end

    property "per-beat mode: every beat once, per-input order, output stable while stalled" do
      check all(
              n <- integer(1..4),
              arbiter <- member_of([:round_robin, :fixed]),
              counts <- list_of(integer(1..12), length: n),
              {vp, rp, seed} <- rates(),
              max_runs: 40
            ) do
        mod = AXIS.merge(n, data: 16, packet: false, arbiter: arbiter)

        ins =
          for {c, i} <- Enum.with_index(counts),
              do: for(j <- 1..c, do: %{tdata: i * 256 + j, tkeep: 3, tlast: 1})

        feed = for {l, i} <- Enum.with_index(ins), into: %{}, do: {:"s#{i}_axis", l}

        r =
          Tb.drive(reset(mod), inputs: feed, outputs: [:m_axis], valid: vp, ready: rp, seed: seed)

        assert Enum.sort(r.out.m_axis) == Enum.sort(List.flatten(ins))

        for l <- ins do
          assert Enum.filter(r.out.m_axis, &(&1 in l)) == l
        end
      end
    end

    test "non-packet mode interleaves beats of different inputs" do
      mod = AXIS.merge(2, data: 8, id: 2, packet: false)
      a = for i <- 1..6, do: %{tdata: i, tkeep: 1, tlast: if(i == 6, do: 1, else: 0), tid: 0}
      b = for i <- 11..16, do: %{tdata: i, tkeep: 1, tlast: if(i == 16, do: 1, else: 0), tid: 1}

      r =
        Tb.drive(reset(mod),
          inputs: %{s0_axis: a, s1_axis: b},
          outputs: [:m_axis],
          valid: 100,
          ready: 100,
          fields: [:tdata, :tkeep, :tlast, :tid]
        )

      ids = Enum.map(r.out.m_axis, & &1.tid)
      assert Enum.sort(r.out.m_axis) == Enum.sort(a ++ b)
      assert ids != Enum.sort(ids) and ids != Enum.sort(ids, :desc)
      assert Enum.filter(r.out.m_axis, &(&1.tid == 0)) == a
    end

    test "packet mode with a fixed arbiter: input 0 wins, packets stay whole" do
      mod = AXIS.merge(2, data: 8, arbiter: :fixed)
      a = Tb.beats("abcdef", 1)
      b = Tb.beats("uvwxyz", 1)

      r =
        Tb.drive(reset(mod),
          inputs: %{s0_axis: a, s1_axis: b},
          outputs: [:m_axis],
          valid: 100,
          ready: 100
        )

      assert Tb.packets(r.out.m_axis, 1) == ["abcdef", "uvwxyz"]
    end
  end

  describe "packet_mux" do
    property "whole packets, per-source order, source tag and done pulses" do
      check all(
              n <- integer(1..5),
              arbiter <- member_of([:round_robin, :fixed]),
              register <- boolean(),
              inputs <- list_of(packets_gen(4), length: n),
              {vp, rp, seed} <- rates(),
              max_runs: 40
            ) do
        mod = AXIS.packet_mux(n, data: 32, user: 3, arbiter: arbiter, register: register)
        ins = for {pk, i} <- Enum.with_index(inputs), do: tagged(pk, i)

        feed =
          for {pk, i} <- Enum.with_index(ins),
              into: %{},
              do: {:"s#{i}_axis", Enum.flat_map(pk, &Tb.beats(&1, 4, %{tuser: i}))}

        r =
          Tb.drive(reset(mod),
            inputs: feed,
            outputs: [:m_axis],
            valid: vp,
            ready: rp,
            seed: seed,
            fields: [:tdata, :tkeep, :tlast, :tuser],
            out_fields: [:tdata, :tkeep, :tlast, :tuser, :src],
            watch: for(i <- 0..(n - 1), do: {:done, i})
          )

        out = Tb.packets(r.out.m_axis, 4)
        assert Enum.sort(out) == Enum.sort(List.flatten(ins))
        for pk <- ins, do: assert(Enum.filter(out, &(&1 in pk)) == pk)

        # every beat carries its source: in src and in the passed-through tuser
        for b <- r.out.m_axis, do: assert(b.src == b.tuser)
        first = for b <- r.out.m_axis, do: b.src
        assert length(first) == length(r.out.m_axis)

        # source of each packet is the tag in its first payload byte
        {_, tags} =
          Enum.reduce(r.out.m_axis, {true, []}, fn b, {start, acc} ->
            acc = if start, do: [{b.src, <<b.tdata::little-8>>} | acc], else: acc
            {b.tlast == 1, acc}
          end)

        for {src, <<tag>>} <- tags, do: assert(src == tag)

        for {pk, i} <- Enum.with_index(ins), do: assert(r.watched[{:done, i}] == length(pk))
      end
    end

    test "fixed priority: requester 0 first, the second packet waits" do
      mod = AXIS.packet_mux(2, data: 8, arbiter: :fixed)

      r =
        Tb.drive(reset(mod),
          inputs: %{s0_axis: Tb.beats("abcd", 1), s1_axis: Tb.beats("wxyz", 1)},
          outputs: [:m_axis],
          valid: 100,
          ready: 100,
          out_fields: [:tdata, :tkeep, :tlast, :src]
        )

      assert Tb.packets(r.out.m_axis, 1) == ["abcd", "wxyz"]
      assert Enum.map(r.out.m_axis, & &1.src) == [0, 0, 0, 0, 1, 1, 1, 1]
    end

    test "src: false drops the port, done still pulses" do
      mod = AXIS.packet_mux(2, data: 8, keep_bits: 1, src: false)
      refute Enum.any?(mod.ports, &(&1.name == :m_axis_src))

      r =
        Tb.drive(reset(mod),
          inputs: %{s0_axis: Tb.beats("ab", 1), s1_axis: Tb.beats("cd", 1)},
          outputs: [:m_axis],
          valid: 100,
          ready: 100,
          watch: [{:done, 0}, {:done, 1}]
        )

      assert Tb.packets(r.out.m_axis, 1) |> Enum.sort() == ["ab", "cd"]
      assert {r.watched[{:done, 0}], r.watched[{:done, 1}]} == {1, 1}
    end

    test "keep_bits sets the width of tkeep (one bit per DWord)" do
      iface = AXIS.iface(data: 256, keep_bits: 8, user: 4)
      assert {:u, 8} == iface.fields |> List.keyfind(:tkeep, 0) |> elem(1)
    end

    test "requires tlast" do
      assert_raise ArgumentError, fn -> AXIS.packet_mux(2, last: false) end
    end
  end

  describe "broadcast" do
    property "every output sees every packet" do
      check all(
              n <- integer(1..4),
              pkts <- packets_gen(),
              {vp, rp, seed} <- rates(),
              max_runs: 40
            ) do
        mod = AXIS.broadcast(n, data: 16, user: 2)
        beats = Enum.flat_map(pkts, &Tb.beats(&1, 2, %{tuser: 2}))
        outs = for i <- 0..(n - 1), do: :"m#{i}_axis"

        r =
          Tb.drive(reset(mod),
            inputs: %{s_axis: beats},
            outputs: outs,
            valid: vp,
            ready: rp,
            seed: seed,
            fields: [:tdata, :tkeep, :tlast, :tuser]
          )

        for o <- outs, do: assert(r.out[o] == beats)
      end
    end
  end

  describe "demux" do
    property "packets are routed by tdest, unknown destinations dropped" do
      check all(
              n <- integer(1..4),
              dests <- uniq_list_of(integer(0..7), length: n),
              pkts <-
                list_of(tuple({binary(min_length: 1, max_length: 15), integer(0..7)}),
                  min_length: 1,
                  max_length: 6
                ),
              {vp, rp, seed} <- rates(),
              max_runs: 40
            ) do
        mod = AXIS.demux(n, data: 16, dest: 3, dests: dests)
        beats = Enum.flat_map(pkts, fn {p, d} -> Tb.beats(p, 2, %{tdest: d}) end)
        outs = for i <- 0..(n - 1), do: :"m#{i}_axis"

        r =
          Tb.drive(reset(mod),
            inputs: %{s_axis: beats},
            outputs: outs,
            valid: vp,
            ready: rp,
            seed: seed,
            fields: [:tdata, :tkeep, :tlast, :tdest]
          )

        for {o, d} <- Enum.zip(outs, dests) do
          want = for {p, ^d} <- pkts, b <- Tb.beats(p, 2, %{tdest: d}), do: b
          assert r.out[o] == want
        end
      end
    end

    test "tdest changing mid-packet does not split the packet" do
      mod = AXIS.demux(2, data: 8, dest: 1)

      beats = [
        %{tdata: 1, tkeep: 1, tlast: 0, tdest: 1},
        %{tdata: 2, tkeep: 1, tlast: 1, tdest: 0}
      ]

      r =
        Tb.drive(reset(mod),
          inputs: %{s_axis: beats},
          outputs: [:m0_axis, :m1_axis],
          valid: 100,
          ready: 100,
          fields: [:tdata, :tkeep, :tlast, :tdest]
        )

      assert r.out.m0_axis == []
      assert Enum.map(r.out.m1_axis, & &1.tdata) == [1, 2]
    end

    test "drop_unknown: false stalls on an unknown destination" do
      mod = AXIS.demux(2, data: 8, dest: 2, drop_unknown: false)
      beats = [%{tdata: 1, tkeep: 1, tlast: 1, tdest: 3}]

      r =
        Tb.drive(reset(mod),
          inputs: %{s_axis: beats},
          outputs: [:m0_axis, :m1_axis],
          max_cycles: 100,
          timeout_ok: true,
          fields: [:tdata, :tkeep, :tlast, :tdest]
        )

      assert r.consumed.s_axis == 0
    end
  end

  describe "Verilator" do
    @describetag :verilator
    @describetag timeout: 600_000

    test "all stream blocks co-simulate" do
      mods = [
        AXIS.skid(data: 16, user: 2),
        AXIS.skid(data: 16, kind: :forward),
        AXIS.upsize(in_bytes: 2, out_bytes: 6, user: 2, id: 2),
        AXIS.downsize(in_bytes: 6, out_bytes: 2, user: 2),
        AXIS.merge(3, data: 16),
        AXIS.packet_mux(3, data: 16, user: 2),
        AXIS.packet_mux(2, data: 8, register: false),
        AXIS.merge(2, data: 8, packet: false, arbiter: :fixed),
        AXIS.broadcast(3, data: 16),
        AXIS.demux(3, data: 16, dest: 2)
      ]

      for {m, i} <- Enum.with_index(mods) do
        Cosim.assert_equivalent(m, Tb.random_stimulus(m, 500, i, bias: %{}))
      end
    end
  end
end
