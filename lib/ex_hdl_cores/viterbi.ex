defmodule ExHdlCores.Viterbi do
  @moduledoc """
  Streaming Viterbi decoder for rate 1/n convolutional codes with
  puncturing, bit for bit the same output as the streaming decoder of
  ex_sdr (`ExSdr.Comm.Convolutional.decoder/2`, `decode_stream/2`,
  `flush/1`) with the same `depth`.

  Defaults are the DVB-T inner code (EN 300 744): K = 7, generators 171 and
  133 octal, 64 states. `dvbt/1` is the decoder for all five DVB-T code
  rates with the rate as `tuser`.

  ## Ports

    * `s_axis_*` - code bits in, one code bit per beat in the low `soft`
      bits of `tdata` (`width` bits, default 8, as ex_sdr's 0/1 bytes).
      The bits are the punctured stream in transmission order (X1 Y1 Y2
      X3 for rate 3/4); the depuncturer inserts the erasures. `tlast`
      marks the last code bit of the stream.
    * `m_axis_*` - decoded bits, one per beat in bit 0 of `tdata`, in
      stream order; `tlast` on the last decoded bit of the stream.
    * `s_axis_tuser` (only with more than one pattern in `puncture:`) - index of
      the puncturing pattern of the stream, read with its first code bit
      (`tuser` of the other beats is ignored), so every stream may use
      another pattern.

  ## Behaviour

  A stream is what ex_sdr sees between creating a decoder and `flush/1`.
  `tlast` flushes: an incomplete puncturing period is completed with
  erasures (also steps without any received bit), the remaining bits are
  traced back from the best end state, and the decoder is reset to its
  start state for the next stream.

  Per trellis step the decoder does a radix-2 add-compare-select on all
  `2^(K - 1)` states in parallel (one step per clock when the input has the
  bits), writes the survivor decisions (one `2^(K - 1)` bit word per step)
  into a block RAM ring of `3 * depth` words and, every `depth` steps from
  `2 * depth` on, traces back `2 * depth` steps from the best state with
  one step per clock and issues the oldest `depth` decoded bits. That is
  the sliding window traceback of ex_sdr: the same best state (lowest
  number on equal metrics), the same tie break in the ACS (the lower
  predecessor), the same windows. Input stalls (`s_axis_tready` low) while
  a traceback is running at a block boundary; the decoded bits wait in two
  output buffers, so the throughput is at most `depth` decoded bits per `2 * depth`
  clocks (50 Mbit/s at 100 MHz; rate 1/2 needs 2.5 clocks per bit, the
  input takes one code bit per clock and the best state scan takes `2^(K - 1)`).

  ## Metrics

  Path metrics are modular integers of `w` bits, the minimum width for
  which every comparison is unambiguous: the spread of the metrics is at
  most `2 * R + 1` with `R = (K - 1) * n * (2^soft - 1)`, the largest cost
  of a path of `K - 1` steps, and the compare takes the sign of a wrapped
  difference. No normalisation is needed. States other than state 0 start
  at `R + 1` (`start: :zero`, ex_sdr's default) or all at 0
  (`start: :unknown`); ex_sdr starts them at 1000 or 1000000, which gives
  the same decisions because only the order of the first `K - 1` steps
  matters.

  ## Options

    * `k:` constraint length (default 7), `polys:` generators, octal as in
      the standards (default `[0o171, 0o133]`, 2 to 4 outputs)
    * `depth:` traceback depth (default 128, as ex_sdr)
    * `puncture:` list of patterns (default one pattern without puncturing),
      a pattern is one 0/1 row per output as in ex_sdr
    * `start:` `:zero` (default) or `:unknown`
    * `soft:` bits per code bit (default 1). With more than one bit the
      value `v` is a soft bit, 0 a sure zero and `2^soft - 1` a sure one;
      the cost of an expected 0 is `v`, of an expected 1 `2^soft - 1 - v`.
      One bit is the hard decision of ex_sdr (cost 1 on a mismatch); more
      bits have no ex_sdr reference, `model/3` is the reference.
    * `width:` bits of `tdata` on both streams (default 8)
    * `name:`

  Decoding errors cannot occur: any bit stream decodes.
  """
  use ExHdl.RTL
  alias ExHdl.RTL.Builder
  import Bitwise, only: [band: 2, bor: 2, bsl: 2, bsr: 2]

  # EN 300 744 table 2, one row per output (X, Y), in the order of `dvbt_rates/0`
  @dvbt %{
    {1, 2} => [[1], [1]],
    {2, 3} => [[1, 0], [1, 1]],
    {3, 4} => [[1, 0, 1], [1, 1, 0]],
    {5, 6} => [[1, 0, 1, 0, 1], [1, 1, 0, 1, 0]],
    {7, 8} => [[1, 0, 0, 0, 1, 0, 1], [1, 1, 1, 1, 0, 1, 0]]
  }
  @dvbt_rates [{1, 2}, {2, 3}, {3, 4}, {5, 6}, {7, 8}]

  @doc "The DVB-T code rates, in the order of the `tuser` of `dvbt/1`."
  def dvbt_rates, do: @dvbt_rates

  @doc "Puncturing pattern (rows X, Y) of a DVB-T code rate."
  def dvbt_pattern(rate), do: Map.fetch!(@dvbt, rate)

  @doc """
  The DVB-T decoder: K = 7, 171/133, all of `dvbt_rates/0` selected by
  `s_axis_tuser` (3 bits, index into that list). Options as `build/1`.
  """
  def dvbt(opts \\ []) do
    build(Keyword.merge([puncture: Enum.map(@dvbt_rates, &dvbt_pattern/1)], opts))
  end

  # -- configuration ------------------------------------------------------------------------

  @doc false
  def config(opts) do
    k = Keyword.get(opts, :k, 7)
    polys = Keyword.get(opts, :polys, [0o171, 0o133])
    n = length(polys)
    depth = Keyword.get(opts, :depth, 128)
    soft = Keyword.get(opts, :soft, 1)
    width = Keyword.get(opts, :width, 8)
    start = Keyword.get(opts, :start, :zero)
    patterns = Keyword.get(opts, :puncture, [List.duplicate([1], n)])

    unless k >= 2 and n in 2..4 and depth >= 1 and soft in 1..8 and width >= soft and
             start in [:zero, :unknown] and patterns != [] and
             Enum.all?(patterns, &valid_pattern?(&1, n)) do
      raise ArgumentError,
            "viterbi: needs K >= 2, 2 to 4 polynomials, depth >= 1, soft in 1..8 <= width, " <>
              "start :zero | :unknown and puncturing rows of 0/1 (one per output, equal length, " <>
              "every step keeps a bit)"
    end

    ns = bsl(1, k - 1)
    maxv = bsl(1, soft) - 1
    bmmax = n * maxv
    r = (k - 1) * bmmax
    clog2 = &Builder.ceil_log2/1

    %{
      k: k,
      polys: polys,
      n: n,
      depth: depth,
      soft: soft,
      width: width,
      start: start,
      patterns: patterns,
      ns: ns,
      maxv: maxv,
      bmmax: bmmax,
      bmw: max(clog2.(bmmax + 1), 1),
      init: r + 1,
      w: clog2.(2 * r + 2 + bmmax) + 1,
      ring: 3 * depth,
      aw: max(clog2.(3 * depth), 1),
      kw: max(clog2.(2 * depth), 1)
    }
  end

  defp valid_pattern?(rows, n) do
    is_list(rows) and length(rows) == n and Enum.all?(rows, &(is_list(&1) and &1 != [])) and
      rows |> Enum.map(&length/1) |> Enum.uniq() |> length() == 1 and
      List.flatten(rows) |> Enum.all?(&(&1 in [0, 1])) and
      rows |> Enum.zip() |> Enum.all?(&(Enum.sum(Tuple.to_list(&1)) > 0))
  end

  # Expected output bits (bit j = generator j) on the branch into state s from the
  # predecessor with lowest bit c; the K-bit encoder register holds the input
  # (the top bit of s) above the predecessor state.
  @doc false
  def branch_pattern(k, polys, s, c) do
    smask = bsl(1, k - 1) - 1
    pred = bor(band(bsl(s, 1), smask), c)
    reg = bor(bsl(bsr(s, k - 2), k - 1), pred)

    polys
    |> Enum.with_index()
    |> Enum.reduce(0, fn {g, j}, acc -> bor(acc, bsl(parity(band(reg, g)), j)) end)
  end

  defp parity(v), do: v |> Integer.digits(2) |> Enum.sum() |> rem(2)

  # {keep mask, kept count, rank per output, last phase?} of every (pattern, phase)
  defp slot_tables(cfg) do
    pw = phase_bits(cfg)
    np = length(cfg.patterns)
    iw = rate_bits(np) + pw

    for i <- 0..(bsl(1, iw) - 1) do
      r = bsr(i, pw)
      p = band(i, bsl(1, pw) - 1)
      rows = Enum.at(cfg.patterns, r, [[]])
      period = length(hd(rows))

      if r < np and p < period do
        keep = for row <- rows, do: Enum.at(row, p)
        ranks = for j <- 0..(cfg.n - 1), do: Enum.sum(Enum.take(keep, j))

        %{
          keep:
            keep |> Enum.with_index() |> Enum.reduce(0, fn {b, j}, a -> bor(a, bsl(b, j)) end),
          count: Enum.sum(keep),
          ranks: ranks,
          last: if(p == period - 1, do: 1, else: 0)
        }
      else
        %{keep: 0, count: 0, ranks: List.duplicate(0, cfg.n), last: 0}
      end
    end
  end

  defp rate_bits(np), do: Builder.ceil_log2(np)

  defp phase_bits(cfg) do
    cfg.patterns |> Enum.map(&length(hd(&1))) |> Enum.max() |> Builder.ceil_log2()
  end

  # -- reference model ----------------------------------------------------------------------

  @doc """
  Reference decoder on integers: the decoded bits of one stream of code
  bits (a list of 0/1, or soft values), flushed at the end. Options as
  `build/1` plus `pattern:` (the puncturing pattern of the stream, default
  the first). Same algorithm as ExSdr's `decode_reference/3` with `depth:`
  (which the tests check it against for hard bits), with the cost of a
  soft bit.
  """
  def ref(bits, opts \\ []) do
    cfg = config(opts)
    pattern = Keyword.get(opts, :pattern, hd(cfg.patterns))
    %{k: k, n: n, depth: depth, ns: ns, maxv: maxv} = cfg
    steps = depuncture(bits, pattern, n)
    smask = ns - 1
    inf = 1_000_000

    table =
      for s <- 0..smask do
        for c <- 0..1 do
          {band(bsl(s, 1), smask) + c, branch_pattern(k, cfg.polys, s, c)}
        end
        |> List.to_tuple()
      end
      |> List.to_tuple()

    dist = fn rx, p ->
      rx
      |> Enum.with_index()
      |> Enum.reduce(0, fn
        {:e, _}, acc -> acc
        {v, j}, acc -> acc + if(band(bsr(p, j), 1) == 1, do: maxv - v, else: v)
      end)
    end

    start =
      for(s <- 0..smask, do: if(cfg.start == :zero and s != 0, do: inf, else: 0))
      |> List.to_tuple()

    {metrics, decisions, bests, count} =
      Enum.reduce(steps, {start, [], %{}, 0}, fn rx, {m, decs, bests, i} ->
        {new, mask} =
          Enum.reduce(smask..0//-1, {[], 0}, fn s, {acc, mask} ->
            {{p0, e0}, {p1, e1}} = elem(table, s)
            c0 = elem(m, p0) + dist.(rx, e0)
            c1 = elem(m, p1) + dist.(rx, e1)
            if c1 < c0, do: {[c1 | acc], bor(mask, bsl(1, s))}, else: {[c0 | acc], mask}
          end)

        new = List.to_tuple(new)
        bests = if rem(i + 1, depth) == 0, do: Map.put(bests, i + 1, best(new)), else: bests
        {new, [mask | decs], bests, i + 1}
      end)

    decisions = decisions |> Enum.reverse() |> List.to_tuple()
    trace = &traceback(decisions, &1, &2, &3, k - 2, smask)

    windows =
      for t <- (2 * depth)..count//depth do
        trace.(bests[t], t - 2 * depth, t) |> Enum.take(depth)
      end

    done = if count >= 2 * depth, do: div(count, depth) * depth - depth, else: 0
    List.flatten([windows | trace.(best(metrics), done, count)])
  end

  defp depuncture(bits, rows, n) do
    slots = rows |> Enum.zip() |> Enum.flat_map(&Tuple.to_list/1)
    per_period = Enum.sum(slots)

    bits
    |> Enum.chunk_every(per_period)
    |> Enum.flat_map(fn chunk ->
      {filled, _} =
        Enum.map_reduce(slots, chunk, fn
          1, [b | rest] -> {b, rest}
          1, [] -> {:e, []}
          0, rest -> {:e, rest}
        end)

      Enum.chunk_every(filled, n)
    end)
  end

  defp best(metrics) do
    {_, s} = metrics |> Tuple.to_list() |> Enum.with_index() |> Enum.min()
    s
  end

  defp traceback(decisions, s, from, to, top, smask) do
    {bits, _} =
      Enum.reduce((to - 1)..from//-1, {[], s}, fn i, {acc, s} ->
        c = band(bsr(elem(decisions, i), s), 1)
        {[bsr(s, top) | acc], bor(band(bsl(s, 1), smask), c)}
      end)

    bits
  end

  # -- module ------------------------------------------------------------------------------

  @doc "Decoder module; see the moduledoc."
  def build(opts \\ []) do
    cfg = config(opts)

    %{
      k: k,
      n: n,
      depth: depth,
      soft: q,
      width: width,
      ns: ns,
      bmw: bmw,
      w: w,
      ring: ring,
      aw: aw,
      kw: kw
    } = cfg

    np = length(cfg.patterns)
    rw = rate_bits(np)
    pw = phase_bits(cfg)
    tables = slot_tables(cfg)
    half = div(ns, 2)
    top = k - 2
    cw = max(Builder.ceil_log2(n + 1), 1)

    tag =
      :erlang.phash2({cfg.polys, cfg.patterns, cfg.start}, 0xFFFFFF)
      |> Integer.to_string(16)
      |> String.downcase()

    default_name = "viterbi_k#{k}_d#{depth}_n#{n}_q#{q}_np#{np}_#{tag}"
    name = Keyword.get(opts, :name, default_name)

    module name do
      s_user = if np > 1, do: input(:s_axis_tuser, rw)
      s_data = input(:s_axis_tdata, width)
      s_valid = input(:s_axis_tvalid, 1)
      s_last = input(:s_axis_tlast, 1)
      s_ready_o = output(:s_axis_tready, 1)
      m_data_o = output(:m_axis_tdata, width, reset: 0)
      m_valid_o = output(:m_axis_tvalid, 1, reset: 0)
      m_last_o = output(:m_axis_tlast, 1, reset: 0)
      m_ready = input(:m_axis_tready, 1)

      # -- depuncturer ----------------------------------------------------------------
      phase = if pw > 0, do: reg(:phase, pw, reset: 0)
      active = reg(:active, 1, reset: 0)

      # the pattern index comes with the first code bit of a stream
      rate_r = if np > 1, do: reg(:rate_r, rw, reset: 0)
      rate = if np > 1, do: mux(active, rate_r, s_user)

      idx =
        case {rate, phase} do
          {nil, nil} -> nil
          {nil, ph} -> ph
          {r, nil} -> r
          {r, ph} -> cat([r, ph])
        end

      tab = fn f, tw ->
        consts = for t <- tables, do: const(f.(t), tw)
        if idx == nil, do: hd(consts), else: mux(idx, consts)
      end

      keep = wire(:keep, tab.(& &1.keep, n))
      cm1 = wire(:cm1, tab.(&max(&1.count - 1, 0), cw))
      lastph = wire(:lastph, tab.(& &1.last, 1))
      ranks = for j <- 0..(n - 1), do: tab.(&Enum.at(&1.ranks, j), cw)

      got = reg(:got, cw, reset: 0)
      have = for j <- 0..(n - 1), do: reg(:"have#{j}", 1, reset: 0)
      vals = for j <- 0..(n - 1), do: reg(:"val#{j}", q, reset: 0)
      tl = reg(:tl, 1, reset: 0)
      st_v = reg(:st_v, 1, reset: 0)
      st_r = reg(:st_r, n * q, reset: 0)
      st_er = reg(:st_er, n, reset: 0)
      st_last = reg(:st_last, 1, reset: 0)

      bm_v = reg(:bm_v, 1, reset: 0)
      bm_last = reg(:bm_last, 1, reset: 0)
      cs = reg(:cs, 3, reset: 0)
      acs_fire = wire(:acs_fire, bm_v and cs == 0)
      bm_free = wire(:bm_free, not bm_v or acs_fire)
      st_free = wire(:st_free, not st_v or bm_free)

      inc = wire(:inc, add_wrap(got, 1))
      would = wire(:would, got == cm1)
      s_ready = wire(:s_ready, not tl and (not would or st_free))
      accept = wire(:accept, s_valid and s_ready)
      complete = wire(:complete, accept and would)
      drain = wire(:drain, tl and st_free)
      emit = wire(:emit, complete or drain)
      sdata = s_data[0..(q - 1)]

      wr = for j <- 0..(n - 1), do: wire(:"wr#{j}", keep[j] and got == Enum.at(ranks, j))
      take = for j <- 0..(n - 1), do: wire(:"take#{j}", accept and Enum.at(wr, j))
      val_n = for j <- 0..(n - 1), do: mux(Enum.at(take, j), sdata, Enum.at(vals, j))
      have_n = for j <- 0..(n - 1), do: Enum.at(have, j) or Enum.at(take, j)

      s_ready_o <~ s_ready

      sync do
        for j <- 0..(n - 1) do
          Enum.at(vals, j) <~ Enum.at(val_n, j)
          Enum.at(have, j) <~ Enum.at(have_n, j)
        end

        if accept, do: got <~ inc
        if st_free, do: st_v <~ emit

        if emit do
          st_r <~ cat(Enum.reverse(val_n))
          st_er <~ cat(for h <- Enum.reverse(have_n), do: not h)
          st_last <~ (lastph and (tl or s_last))
          got <~ 0
          for h <- have, do: h <~ 0
          if phase != nil, do: phase <~ mux(lastph, const(0, pw), add_wrap(phase, 1))
        end

        if accept and s_last and not (complete and lastph), do: tl <~ 1
        if drain and lastph, do: tl <~ 0

        if rate_r != nil and accept and not active, do: rate_r <~ s_user
        if accept, do: active <~ 1
        if (complete and s_last and lastph) or (drain and lastph), do: active <~ 0
      end

      # -- branch metrics: cost of every possible expected pattern --------------------
      bms =
        for p <- 0..(bsl(1, n) - 1) do
          costs =
            for j <- 0..(n - 1) do
              v = st_r[(j * q)..(j * q + q - 1)]
              c = if band(bsr(p, j), 1) == 1, do: ~~~v, else: v
              resize(mux(st_er[j], const(0, q), c), bmw)
            end

          Enum.reduce(costs, const(0, bmw), &add_wrap/2)
        end

      bmr = for p <- 0..(bsl(1, n) - 1), do: reg(:"bm#{p}", bmw, reset: 0)

      sync do
        if bm_free do
          bm_v <~ st_v
          bm_last <~ st_last
          for {r, e} <- Enum.zip(bmr, bms), do: r <~ e
        end
      end

      # -- metrics, add-compare-select ------------------------------------------------
      pm =
        for s <- 0..(ns - 1) do
          init = if cfg.start == :zero and s != 0, do: cfg.init, else: 0
          reg(:"pm#{s}", w, reset: init)
        end

      acs =
        for s <- 0..(ns - 1) do
          base = rem(s, half) * 2

          [c0, c1] =
            for c <- 0..1 do
              m = Enum.at(pm, base + c)
              b = Enum.at(bmr, branch_pattern(k, cfg.polys, s, c))
              add_wrap(m, resize(b, w))
            end

          lt = sub_wrap(c1, c0)[w - 1]
          {mux(lt, c1, c0), lt}
        end

      dec_word = wire(:dec_word, cat(for {_, lt} <- Enum.reverse(acs), do: lt))

      # -- control: block and stream bookkeeping, best state scan ---------------------
      off = reg(:off, kw, reset: 0)
      nblk = reg(:nblk, 2, reset: 0)
      wr_ptr = reg(:wr_ptr, aw, reset: 0)
      scan_i = reg(:scan_i, k - 1, reset: 0)
      best_val = reg(:best_val, w, reset: 0)
      best_idx = reg(:best_idx, k - 1, reset: 0)
      p_reg = reg(:p_reg, 1, reset: 0)
      p_fl = reg(:p_fl, 1, reset: 0)

      blk_end = wire(:blk_end, off == depth - 1)
      stop = wire(:stop, acs_fire and (blk_end or bm_last))

      # the scan reads one metric per clock into `cur`, compares it a clock later
      cur = reg(:cur, w, reset: 0)
      cur_i = reg(:cur_i, k - 1, reset: 0)
      cur_v = reg(:cur_v, 1, reset: 0)
      better = wire(:better, cur_i == 0 or sub_wrap(cur, best_val)[w - 1])

      # traceback engine
      a_run = reg(:a_run, 1, reset: 0)
      a_addr = reg(:a_addr, aw, reset: 0)
      a_k = reg(:a_k, kw, reset: 0)
      b_v = reg(:b_v, 1, reset: 0)
      b_k = reg(:b_k, kw, reset: 0)
      tb_s = reg(:tb_s, k - 1, reset: 0)
      job_out = reg(:job_out, kw, reset: 0)
      job_half = reg(:job_half, 1, reset: 0)
      job_last = reg(:job_last, 1, reset: 0)
      wr_half = reg(:wr_half, 1, reset: 0)
      full = for h <- 0..1, do: reg(:"full#{h}", 1, reset: 0)
      olen = for h <- 0..1, do: reg(:"olen#{h}", kw, reset: 0)
      olast = for h <- 0..1, do: reg(:"olast#{h}", 1, reset: 0)

      eng_idle = wire(:eng_idle, not a_run and not b_v)
      can_launch = wire(:can_launch, eng_idle and not mux(wr_half, full))
      launch_r = wire(:launch_r, cs == 2 and can_launch and p_reg)
      launch_f = wire(:launch_f, cs == 3 and can_launch)
      launch = wire(:launch, launch_r or launch_f)

      # steps of the flush traceback: those since the last emitted window
      fl_len = wire(:fl_len, add_wrap(off, mux(nblk != 0, const(depth, kw), const(0, kw))))

      mem = memory(:dec, width: ns, depth: ring, style: :block)
      write_port(mem, addr: wr_ptr, data: dec_word, en: acs_fire)
      rdata = read_port(mem, addr: a_addr, en: a_run)
      last_addr = wire(:last_addr, mux(wr_ptr == 0, const(ring - 1, aw), sub_wrap(wr_ptr, 1)))

      sync do
        if acs_fire do
          wr_ptr <~ mux(wr_ptr == ring - 1, const(0, aw), add_wrap(wr_ptr, 1))
          off <~ mux(blk_end, const(0, kw), add_wrap(off, 1))
          if blk_end and nblk != 2, do: nblk <~ add_wrap(nblk, 1)
          for {m, {nx, _}} <- Enum.zip(pm, acs), do: m <~ nx
        end

        if stop do
          cs <~ 1
          scan_i <~ 0
          p_reg <~ (blk_end and nblk != 0)
          p_fl <~ bm_last
        end

        if cs == 1 do
          cur <~ mux(scan_i, pm)
          cur_i <~ scan_i
          scan_i <~ add_wrap(scan_i, 1)
          if scan_i == ns - 1, do: cs <~ 4
        end

        cur_v <~ (cs == 1)

        if cur_v and better do
          best_val <~ cur
          best_idx <~ cur_i
        end

        if cs == 4 and not cur_v, do: cs <~ 2

        if cs == 2 and can_launch, do: cs <~ mux(p_fl, const(3, 3), const(0, 3))

        if launch_f do
          cs <~ 0
          off <~ 0
          nblk <~ 0

          for {m, s} <- Enum.zip(pm, 0..(ns - 1)),
              do: m <~ if(cfg.start == :zero and s != 0, do: cfg.init, else: 0)
        end

        # engine, address stage then decision stage
        if launch do
          a_run <~ 1
          a_addr <~ last_addr
          a_k <~ mux(launch_f, sub_wrap(fl_len, 1), const(2 * depth - 1, kw))
          job_out <~ mux(launch_f, fl_len, const(depth, kw))
          job_last <~ launch_f
          job_half <~ wr_half
          tb_s <~ best_idx
        end

        if a_run do
          a_addr <~ mux(a_addr == 0, const(ring - 1, aw), sub_wrap(a_addr, 1))
          a_k <~ sub_wrap(a_k, 1)
          if a_k == 0, do: a_run <~ 0
        end

        b_v <~ a_run
        b_k <~ a_k
      end

      # decision stage: one traceback step per clock
      dbit = wire(:dbit, rdata[tb_s])
      jdone = wire(:jdone, b_v and b_k == 0)

      obuf = memory(:obuf, width: 1, depth: bsl(1, kw + 1), style: :distributed)

      write_port(obuf,
        addr: cat([job_half, b_k]),
        data: tb_s[top],
        en: b_v and b_k < job_out
      )

      sync do
        if b_v, do: tb_s <~ cat([slice(tb_s, 0, k - 2), dbit])

        if jdone do
          wr_half <~ not wr_half

          for h <- 0..1 do
            if job_half == h do
              Enum.at(full, h) <~ 1
              Enum.at(olen, h) <~ job_out
              Enum.at(olast, h) <~ job_last
            end
          end
        end
      end

      # -- output side ------------------------------------------------------------------
      rd_half = reg(:rd_half, 1, reset: 0)
      rp = reg(:rp, kw, reset: 0)
      rp1 = reg(:rp1, kw, reset: 1)
      cur_full = wire(:cur_full, mux(rd_half, full))
      cur_len = wire(:cur_len, mux(rd_half, olen))
      cur_last = wire(:cur_last, mux(rd_half, olast))
      m_free = wire(:m_free, not m_valid_o or m_ready)
      load = wire(:load, cur_full and m_free)
      at_end = wire(:at_end, rp1 == cur_len)
      obit = read_port(obuf, kind: :async, addr: cat([rd_half, rp]))

      sync do
        if m_free do
          m_valid_o <~ load
          m_data_o <~ zext(obit, width)
          m_last_o <~ (cur_last and at_end)
        end

        if load do
          rp <~ rp1
          rp1 <~ add_wrap(rp1, 1)

          if at_end do
            rp <~ 0
            rp1 <~ 1
            rd_half <~ not rd_half

            for h <- 0..1, do: if(rd_half == h, do: Enum.at(full, h) <~ 0)
          end
        end
      end
    end
  end
end
