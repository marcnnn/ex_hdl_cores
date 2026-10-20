defmodule ExHdlCores.FIFOTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.{FIFO, Tb}
  alias ExHdlCores.FIFO.Model

  defp b(x), do: if(x, do: 1, else: 0)

  # Random phases (write heavy, read heavy, balanced); checks count, full,
  # almost flags, empty, order and rd_valid against the model.
  defp run_sync(mod, depth, opts, seed, cycles \\ 400) do
    :rand.seed(:exsss, {seed, 7, 8})
    fwft = Keyword.get(opts, :fwft, true)
    distributed = Keyword.get(opts, :style) == :distributed
    af = opts[:almost_full]
    ae = opts[:almost_empty]
    sim = mod |> Sim.new() |> Sim.reset()

    phases =
      for _ <- 1..(div(cycles, 40) + 1),
          do: {Enum.random([10, 50, 90]), Enum.random([10, 50, 90])}

    init = {sim, Model.new(depth), 0, nil, 0, 0}

    {sim, m, _, _, pops, _} =
      Enum.reduce(0..(cycles - 1), init, fn i, {sim, m, next, prev_pop, pops, quiet} ->
        {pw, pr} = Enum.at(phases, div(i, 40))
        wr = :rand.uniform(100) <= pw
        rd = :rand.uniform(100) <= pr
        sim = Sim.poke(sim, %{wr_en: b(wr), wr_data: rem(next, 256), rd_en: b(rd)})
        o = Sim.outputs(sim)
        n = Model.count(m)

        assert o.count == n
        assert o.full == b(n == depth)
        if af, do: assert(o.almost_full == b(n >= af))
        if ae, do: assert(o.almost_empty == b(n <= ae))
        if n == 0, do: assert(o.empty == 1)
        if o.empty == 0, do: assert(n > 0)
        if fwft and (distributed or n > 2), do: assert(o.empty == b(n == 0) or not distributed)
        if distributed and fwft, do: assert(o.empty == b(n == 0))

        if not fwft do
          assert o.rd_valid == b(prev_pop != nil)
          if prev_pop != nil, do: assert(o.rd_data == prev_pop)
        end

        pop = rd and o.empty == 0
        head = Model.head(m)
        if pop and fwft, do: assert(o.rd_data == head)
        if o.empty == 0 and fwft, do: assert(o.rd_data == head)
        push = wr and o.full == 0
        {m, popped} = Model.step(m, if(wr, do: rem(next, 256)), pop)
        quiet = if push or pop, do: 0, else: quiet + 1

        {Sim.step(sim), m, if(push, do: next + 1, else: next), if(not fwft, do: popped),
         pops + b(pop), quiet}
      end)

    # drain: everything stored comes out, in order, within count + 4 cycles
    drained =
      Enum.reduce_while(1..(Model.count(m) + 8), {sim, m, []}, fn _, {sim, m, got} ->
        sim = Sim.poke(sim, %{wr_en: 0, rd_en: 1})
        o = Sim.outputs(sim)
        pop = o.empty == 0
        {m, v} = Model.step(m, nil, pop)
        got = if pop and fwft, do: [{o.rd_data, Model.head(m)} | got], else: got
        _ = v
        sim = Sim.step(sim)
        if Model.empty?(m), do: {:halt, {sim, m, got}}, else: {:cont, {sim, m, got}}
      end)

    {_, m2, _} = drained
    assert Model.empty?(m2), "FIFO did not drain: #{Model.count(m2)} entries left"
    pops
  end

  property "synchronous FIFO matches the model" do
    check all(
            aw <- integer(1..4),
            style <- member_of([:block, :distributed, :ultra]),
            fwft <- boolean(),
            af <- one_of([constant(nil), integer(1..4)]),
            ae <- one_of([constant(nil), integer(0..3)]),
            seed <- integer(),
            max_runs: 30
          ) do
      depth = 1 <<< aw
      opts = [width: 8, depth: depth, style: style, fwft: fwft, almost_full: af, almost_empty: ae]
      mod = FIFO.sync_fifo(opts)
      assert run_sync(mod, depth, opts, seed) > 0
    end
  end

  test "FWFT block RAM FIFO streams one entry per cycle" do
    mod = FIFO.sync_fifo(width: 8, depth: 32)
    sim = mod |> Sim.new() |> Sim.reset() |> Sim.poke(%{wr_en: 1, rd_en: 0})

    sim =
      Enum.reduce(1..20, sim, fn i, sim -> sim |> Sim.poke(:wr_data, i) |> Sim.step() end)
      |> Sim.poke(%{wr_en: 0, rd_en: 1})

    {_, got} =
      Enum.reduce(1..20, {sim, []}, fn _, {sim, got} ->
        {Sim.step(sim), [Sim.peek(sim, :rd_data) | got]}
      end)

    assert Enum.reverse(got) == Enum.to_list(1..20)
  end

  test "sync FIFO rejects other depths" do
    assert_raise ArgumentError, ~r/power of two/, fn -> FIFO.sync_fifo(depth: 12) end
  end

  # -- asynchronous FIFO -----------------------------------------------------------------

  @clocks [
    [wr: [period: 10], rd: [period: 13, phase: 4]],
    [wr: [period: 7], rd: [period: 10, phase: 3]],
    [wr: [period: 10], rd: [period: 10, phase: 5]]
  ]

  defp run_async(mod, depth, style, clocks, seed, cycles \\ 1500) do
    :rand.seed(:exsss, {seed, 3, 4})
    cap = if style == :distributed, do: depth, else: depth + 1
    sim = Sim.new(mod, clocks: clocks)

    sim =
      sim
      |> Sim.poke(%{rst_wr_n: 0, rst_rd_n: 0})
      |> Sim.step(8)
      |> Sim.poke(%{rst_wr_n: 1, rst_rd_n: 1})

    phases =
      for _ <- 0..div(cycles, 100), do: {Enum.random([10, 50, 90]), Enum.random([10, 50, 90])}

    {sim, q, _next, max_fill} =
      Enum.reduce(0..(cycles - 1), {sim, :queue.new(), 0, 0}, fn i, {sim, q, next, max_fill} ->
        {pw, pr} = Enum.at(phases, div(i, 100))
        wr = :rand.uniform(100) <= pw
        rd = :rand.uniform(100) <= pr
        sim = Sim.poke(sim, %{wr_en: b(wr), wr_data: rem(next, 256), rd_en: b(rd)})
        o = Sim.outputs(sim)
        edges = Sim.next_edges(sim)
        push = wr and o.full == 0 and :clk_wr in edges
        pop = rd and o.empty == 0 and :clk_rd in edges
        n = :queue.len(q)
        if o.empty == 0, do: assert(n > 0)
        if n >= cap, do: assert(o.full == 1)

        q =
          if pop do
            {{:value, v}, q2} = :queue.out(q)
            assert o.rd_data == v
            q2
          else
            q
          end

        q = if push, do: :queue.in(rem(next, 256), q), else: q
        assert :queue.len(q) <= cap
        {Sim.step(sim), q, if(push, do: next + 1, else: next), max(max_fill, :queue.len(q))}
      end)

    # drain
    {_, q} =
      Enum.reduce_while(1..200, {Sim.poke(sim, %{wr_en: 0, rd_en: 1}), q}, fn _, {sim, q} ->
        o = Sim.outputs(sim)
        edges = Sim.next_edges(sim)

        q =
          if o.empty == 0 and :clk_rd in edges do
            {{:value, v}, q2} = :queue.out(q)
            assert o.rd_data == v
            q2
          else
            q
          end

        if :queue.is_empty(q), do: {:halt, {sim, q}}, else: {:cont, {Sim.step(sim), q}}
      end)

    assert :queue.is_empty(q), "async FIFO did not drain"
    max_fill
  end

  property "asynchronous FIFO keeps order across clocks and never overflows" do
    check all(
            aw <- integer(1..4),
            style <- member_of([:block, :distributed]),
            clocks <- member_of(@clocks),
            seed <- integer(),
            max_runs: 25
          ) do
      mod = FIFO.async_fifo(width: 8, depth: 1 <<< aw, style: style)
      run_async(mod, 1 <<< aw, style, clocks, seed)
    end
  end

  test "asynchronous FIFO fills to its capacity" do
    for {style, cap} <- [distributed: 8, block: 9] do
      mod = FIFO.async_fifo(width: 8, depth: 8, style: style)
      assert run_async(mod, 8, style, hd(@clocks), 1) <= cap
      sim = Sim.new(mod, clocks: hd(@clocks))

      sim =
        sim
        |> Sim.poke(%{rst_wr_n: 0, rst_rd_n: 0})
        |> Sim.step(8)
        |> Sim.poke(%{rst_wr_n: 1, rst_rd_n: 1, wr_en: 1, rd_en: 0})

      sim =
        Enum.reduce(1..60, sim, fn i, sim -> sim |> Sim.poke(:wr_data, i) |> Sim.cycle(:wr) end)

      assert Sim.peek(sim, :full) == 1
      sim = Sim.poke(sim, %{wr_en: 0, rd_en: 1})

      {_, got} =
        Enum.reduce(1..60, {sim, []}, fn _, {sim, got} ->
          o = Sim.outputs(sim)

          got =
            if o.empty == 0 and :clk_rd in Sim.next_edges(sim), do: [o.rd_data | got], else: got

          {Sim.step(sim), got}
        end)

      assert Enum.reverse(got) == Enum.to_list(1..cap)
    end
  end

  test "async fill levels bound the true level" do
    mod = FIFO.async_fifo(width: 8, depth: 8, style: :distributed, count: true)
    sim = Sim.new(mod, clocks: hd(@clocks))

    sim =
      sim
      |> Sim.poke(%{rst_wr_n: 0, rst_rd_n: 0})
      |> Sim.step(8)
      |> Sim.poke(%{rst_wr_n: 1, rst_rd_n: 1, wr_en: 1, rd_en: 0})

    sim =
      Enum.reduce(1..5, sim, fn i, sim -> sim |> Sim.poke(:wr_data, i) |> Sim.cycle(:wr) end)
      |> Sim.poke(:wr_en, 0)

    assert Sim.peek(sim, :wr_count) == 5
    sim = Sim.cycle(sim, :rd, 4)
    assert Sim.peek(sim, :rd_count) == 5
  end

  # -- AXI4-Stream FIFOs -----------------------------------------------------------------

  defp pkts_gen, do: list_of(binary(min_length: 1, max_length: 19), min_length: 1, max_length: 8)

  property "sync AXI4-Stream FIFO passes every beat, protocol kept" do
    check all(
            pkts <- pkts_gen(),
            style <- member_of([:block, :distributed]),
            vp <- integer(20..100),
            rp <- integer(20..100),
            seed <- integer(),
            max_runs: 25
          ) do
      mod = FIFO.axis(data: 16, user: 2, depth: 16, style: style, almost_full: 12, count: true)
      beats = Enum.flat_map(pkts, &Tb.beats(&1, 2, %{tuser: 1}))
      sim = mod |> Sim.new() |> Sim.reset()

      r =
        Tb.drive(sim,
          inputs: %{s_axis: beats},
          outputs: [:m_axis],
          valid: vp,
          ready: rp,
          seed: seed,
          fields: [:tdata, :tkeep, :tlast, :tuser]
        )

      assert r.out.m_axis == beats
    end
  end

  property "async AXI4-Stream FIFO passes every beat across clocks" do
    check all(
            pkts <- pkts_gen(),
            style <- member_of([:block, :distributed]),
            clocks <- member_of(@clocks),
            vp <- integer(20..100),
            rp <- integer(20..100),
            seed <- integer(),
            max_runs: 15
          ) do
      mod = FIFO.axis_async(data: 16, depth: 8, style: style)
      beats = Enum.flat_map(pkts, &Tb.beats(&1, 2))

      sim =
        mod
        |> Sim.new(clocks: clocks)
        |> Sim.poke(%{rst_wr_n: 0, rst_rd_n: 0})
        |> Sim.step(8)
        |> Sim.poke(%{rst_wr_n: 1, rst_rd_n: 1})

      r =
        Tb.drive(sim,
          inputs: %{s_axis: beats},
          outputs: [:m_axis],
          valid: vp,
          ready: rp,
          seed: seed,
          idle: 80,
          max_cycles: 60_000,
          clocks: %{s_axis: :clk_wr, m_axis: :clk_rd}
        )

      assert r.out.m_axis == beats
    end
  end

  # -- packet FIFO -----------------------------------------------------------------------

  # Packets with an error flag on the last beat's tuser bit 0 and noise elsewhere.
  defp packet_beats(pkts, bytes) do
    Enum.flat_map(pkts, fn {p, bad} ->
      beats = Tb.beats(p, bytes)
      n = length(beats)

      beats
      |> Enum.with_index(1)
      |> Enum.map(fn {beat, i} ->
        user = if i == n, do: b(bad), else: :rand.uniform(2) - 1
        Map.put(beat, :tuser, user)
      end)
    end)
  end

  property "packet FIFO drops packets flagged bad and forwards the others whole" do
    check all(
            pkts <-
              list_of(tuple({binary(min_length: 1, max_length: 19), boolean()}),
                min_length: 1,
                max_length: 10
              ),
            style <- member_of([:block, :distributed]),
            vp <- integer(20..100),
            rp <- integer(20..100),
            seed <- integer(),
            max_runs: 25
          ) do
      :rand.seed(:exsss, {seed, 5, 5})
      mod = FIFO.packet(data: 16, user: 1, depth: 32, style: style, drop_on_full: false)
      beats = packet_beats(pkts, 2)

      r =
        Tb.drive(mod |> Sim.new() |> Sim.reset(),
          inputs: %{s_axis: beats},
          outputs: [:m_axis],
          valid: vp,
          ready: rp,
          seed: seed,
          fields: [:tdata, :tkeep, :tlast, :tuser],
          watch: [:drop_bad, :drop_full]
        )

      good = for {p, false} <- pkts, do: p
      assert Tb.packets(r.out.m_axis, 2) == good
      assert r.watched.drop_bad == Enum.count(pkts, &elem(&1, 1))
      assert r.watched.drop_full == 0
    end
  end

  property "packet FIFO that overflows drops whole packets only, in order" do
    check all(
            pkts <-
              list_of(tuple({binary(min_length: 1, max_length: 30), boolean()}),
                min_length: 2,
                max_length: 12
              ),
            rp <- integer(5..60),
            seed <- integer(),
            max_runs: 25
          ) do
      :rand.seed(:exsss, {seed, 6, 6})
      mod = FIFO.packet(data: 16, user: 1, depth: 8)
      beats = packet_beats(pkts, 2)

      r =
        Tb.drive(mod |> Sim.new() |> Sim.reset(),
          inputs: %{s_axis: beats},
          outputs: [:m_axis],
          valid: 100,
          ready: rp,
          seed: seed,
          fields: [:tdata, :tkeep, :tlast, :tuser],
          watch: [:drop_bad, :drop_full]
        )

      assert r.consumed.s_axis == length(beats)
      out = Tb.packets(r.out.m_axis, 2)
      good = for {p, false} <- pkts, do: p
      # a subsequence of the good packets
      assert subsequence?(out, good)
      assert length(out) + r.watched.drop_bad + r.watched.drop_full == length(pkts)
      assert Enum.all?(out, &(byte_size(&1) <= 16))
    end
  end

  test "packet FIFO: an oversized packet is dropped, the next one passes" do
    mod = FIFO.packet(data: 16, user: 1, depth: 4)
    big = String.duplicate("x", 20)
    :rand.seed(:exsss, {1, 2, 3})
    beats = packet_beats([{big, false}, {"hi", false}], 2)

    r =
      Tb.drive(mod |> Sim.new() |> Sim.reset(),
        inputs: %{s_axis: beats},
        outputs: [:m_axis],
        valid: 100,
        ready: 100,
        fields: [:tdata, :tkeep, :tlast, :tuser],
        watch: [:drop_full]
      )

    assert Tb.packets(r.out.m_axis, 2) == ["hi"]
    assert r.watched.drop_full == 1
  end

  defp subsequence?([], _), do: true
  defp subsequence?(_, []), do: false
  defp subsequence?([x | xs], [x | ys]), do: subsequence?(xs, ys)
  defp subsequence?(xs, [_ | ys]), do: subsequence?(xs, ys)

  # -- Verilator -------------------------------------------------------------------------

  describe "Verilator" do
    @describetag :verilator
    @describetag timeout: 600_000

    test "synchronous FIFOs and the packet FIFO co-simulate" do
      mods = [
        FIFO.sync_fifo(width: 8, depth: 8),
        FIFO.sync_fifo(
          width: 12,
          depth: 16,
          style: :distributed,
          almost_full: 12,
          almost_empty: 2
        ),
        FIFO.sync_fifo(width: 8, depth: 8, fwft: false),
        FIFO.sync_fifo(width: 8, depth: 8, fwft: false, style: :distributed),
        FIFO.axis(data: 16, user: 1, depth: 8, count: true),
        FIFO.packet(data: 16, user: 2, depth: 8, err_bit: 1),
        FIFO.packet(data: 16, user: 1, depth: 8, drop_on_full: false, style: :distributed)
      ]

      for {m, i} <- Enum.with_index(mods) do
        Cosim.assert_equivalent(m, Tb.random_stimulus(m, 600, i, bias: %{s_axis_tlast: 25}))
      end
    end

    test "asynchronous FIFOs co-simulate with two clocks" do
      clocks = [wr: [period: 10], rd: [period: 13, phase: 4]]

      mods = [
        FIFO.async_fifo(width: 8, depth: 8),
        FIFO.async_fifo(width: 8, depth: 4, style: :distributed, count: true),
        FIFO.axis_async(data: 16, depth: 8)
      ]

      for {m, i} <- Enum.with_index(mods) do
        Cosim.assert_equivalent(m, Tb.random_stimulus(m, 1500, i, reset: 8), clocks: clocks)
      end
    end
  end
end
