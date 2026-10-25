defmodule ExHdlCores.ReedSolomon do
  @moduledoc """
  Reed-Solomon decoder for byte streams, one symbol per clock, several
  codewords in flight. Systematic codes over GF(2^m), shortened, with any
  field polynomial, first consecutive root `fcr` and root step `prim` (the
  generator has the roots `alpha^(prim * (fcr + i))`), the same code
  parameters and decoding rules as `ExSdr.Comm.ReedSolomon`; `dvbt/0` is
  RS(204, 188) of DVB.

  Options: `n:`, `k:`, `m:` (default 8), `field_poly:` (default `0x11D`),
  `fcr:` (0), `prim:` (1), `shortening:` (0), `slots:` (codeword buffers, a
  power of two, default 4).

  Ports: `s_axis` takes `n - shortening` symbols per codeword in the low
  `m` bits of `tdata` (first symbol = highest power); codewords are
  delimited by counting, there is no `s_axis_tlast`. `m_axis` gives the
  `k - shortening` message symbols with `tlast` on the last; `tuser` is
  `{corrected, failed}` of the whole codeword on every beat (bit 0 failed,
  bit 1 at least one symbol corrected). A failed codeword (more than
  `(n - k) / 2` errors, or a locator that does not have as many roots as
  its degree inside the transmitted part) goes through uncorrected. The
  statistics pulse `stat_valid` in the cycle the last symbol of a codeword is
  transferred; `stat_failed` (1 for a failed codeword) and `stat_errors`
  (symbols corrected, 0 when failed) are 0 in every other cycle, so they
  can be summed into counters.

  Structure, per codeword (every stage takes at most `n - shortening`
  cycles, so a new codeword can start every `n - shortening` cycles with no
  gap between codewords on the input):

    1. syndromes by Horner's rule, one constant multiplier per root, while
       the symbols go into a ring of `slots` codeword buffers (block RAM)
    2. inversionless Berlekamp-Massey with `t + 1` shared multipliers, three
       cycles per iteration (discrepancy, `B * d`, `gamma * lambda`), then
       the error evaluator `omega = S * lambda mod x^(n-k)` by replaying
       the discrepancy product once more
    3. Chien search, one position per clock over the transmitted part, with
       Forney's algorithm pipelined behind it (inverse table, two
       multipliers); the error values are written into a second buffer
       ring, zero for positions that are no roots
    4. output: data xor error value, or the data unchanged if the codeword
       failed

  The decision rule is that of the reference: failed when the locator
  degree exceeds `t` or the number of roots among the transmitted
  positions differs from the degree (a root in the shortened part is such a
  case). One deliberate difference: the locator registers hold `t + 1`
  coefficients, so a word whose Berlekamp-Massey register length `L`
  exceeds `t` is failed even if the reference ends up with a locator of
  degree at most `t`. The data is passed on uncorrected in that case too;
  the flags differ only when the reference reports "decoded, 0 corrections"
  or finds a full set of roots. That needs contrived syndromes (for random
  garbage about 1 word in 10^5 reaches `L > t` with a short locator, and
  one in 10^9 or fewer then also passes the root test); the test builds one
  from `(0, s, 0, ..., 0, s', 0, ...)`.

  Backpressure: `s_axis_tready` drops when all buffers hold codewords that
  have not been read out or the previous syndromes wait for the
  Berlekamp-Massey stage; the output pipeline advances on `m_axis_tready`.
  Latency about `2 * (n - shortening) + 70` cycles.
  """
  use ExHdl.RTL
  alias Bitwise, as: B
  alias ExHdl.RTL.Builder
  alias ExHdlCores.{AXIS, GF}

  @doc "The DVB code RS(204, 188) of ETSI EN 300 744: RS(255, 239) shortened by 51."
  def dvbt(opts \\ []), do: build([n: 255, k: 239, shortening: 51] ++ opts)

  def build(opts) do
    m = Keyword.get(opts, :m, 8)
    poly = Keyword.get(opts, :field_poly, 0x11D)
    n = Keyword.fetch!(opts, :n)
    k = Keyword.fetch!(opts, :k)
    fcr = Keyword.get(opts, :fcr, 0)
    prim = Keyword.get(opts, :prim, 1)
    short = Keyword.get(opts, :shortening, 0)
    slots = Keyword.get(opts, :slots, 4)

    f = GF.new(m, poly)
    np = n - k
    t = div(np, 2)
    len = n - short
    msg = k - short

    unless n <= GF.order(f) and np >= 2 and rem(np, 2) == 0 and short < k and
             Integer.gcd(prim, GF.order(f)) == 1 and slots >= 2 and
             B.band(slots, slots - 1) == 0,
           do:
             raise(
               ArgumentError,
               "reed solomon: need n <= 2^m - 1, an even n - k >= 2, shortening < k, " <>
                 "prim coprime to 2^m - 1 and a power of two slots"
             )

    dw = div(m + 7, 8) * 8
    aw = max(Builder.ceil_log2(len), 1)
    sb = Builder.ceil_log2(slots)
    rw = max(Builder.ceil_log2(np), 1)
    lw = Builder.ceil_log2(np + 1)
    dgw = max(Builder.ceil_log2(t + 1), 1)
    rcw = dgw
    root = fn e -> GF.pow(f, prim * e) end

    name =
      "rs_#{n}_#{k}_s#{short}_m#{m}_g#{Integer.to_string(poly, 16)}_f#{fcr}_p#{prim}_x#{slots}"

    module name do
      s = slave(:s_axis, AXIS.iface(data: dw, keep: false, last: false))
      mo = master(:m_axis, AXIS.iface(data: dw, keep: false, user: 2))
      stat_valid = output(:stat_valid, 1)
      stat_failed = output(:stat_failed, 1)
      stat_errors = output(:stat_errors, dgw)

      sym = if dw == m, do: s.tdata, else: s.tdata[0..(m - 1)]

      # -- input: syndromes and the data ring --------------------------------------------
      a_idx = reg(:a_idx, aw)
      wp = reg(:wp, sb + 1)
      syn = for i <- 0..(np - 1), do: reg(:"syn_#{i}", m, reset: nil)
      syn_pend = reg(:syn_pend, 1)

      # -- Berlekamp-Massey ------------------------------------------------------------------
      bs = reg(:bs, 2)
      ph = reg(:ph, 2)
      r = reg(:r, rw)
      l = reg(:l, lw)
      gamma = reg(:gamma, m, reset: nil)
      d = reg(:d, m, reset: nil)
      lam = for i <- 0..t, do: reg(:"lam_#{i}", m, reset: nil)
      bb = for i <- 0..t, do: reg(:"bb_#{i}", m, reset: nil)
      tt = for i <- 0..t, do: reg(:"tt_#{i}", m, reset: nil)
      w = for i <- 0..t, do: reg(:"w_#{i}", m, reset: nil)
      q = for i <- 0..(np - 1), do: reg(:"q_#{i}", m, reset: nil)
      om = for i <- 0..(np - 1), do: reg(:"om_#{i}", m, reset: nil)

      # -- Chien search and Forney -------------------------------------------------------------
      cz_active = reg(:cz_active, 1)
      cz_idx = reg(:cz_idx, aw, reset: nil)
      cz_deg = reg(:cz_deg, dgw, reset: nil)
      cz_ovf = reg(:cz_ovf, 1, reset: nil)
      cl = for i <- 0..t, do: reg(:"cl_#{i}", m, reset: nil)
      co = for i <- 0..(np - 1), do: reg(:"co_#{i}", m, reset: nil)
      cz_y = if fcr != 0, do: reg(:cz_y, m, reset: nil)
      rc = reg(:rc, rcw)
      cp = reg(:cp, sb + 1)

      stage = fn pre, extra ->
        base = %{
          v: reg(:"#{pre}_v", 1),
          idx: reg(:"#{pre}_idx", aw, reset: nil),
          last: reg(:"#{pre}_last", 1, reset: nil),
          root: reg(:"#{pre}_root", 1, reset: nil),
          deg: reg(:"#{pre}_deg", dgw, reset: nil),
          ovf: reg(:"#{pre}_ovf", 1, reset: nil)
        }

        Enum.reduce(extra, base, fn fld, acc ->
          Map.put(acc, fld, reg(:"#{pre}_#{fld}", m, reset: nil))
        end)
      end

      ys = if fcr != 0, do: [:y], else: []
      p1 = stage.("p1", [:a, :b] ++ ys)
      p2 = stage.("p2", [:a, :b] ++ ys)
      p3 = stage.("p3", [:a] ++ ys)
      p4 = stage.("p4", [:a])

      meta_f = for i <- 0..(slots - 1), do: reg(:"meta_f_#{i}", 1, reset: nil)
      meta_e = for i <- 0..(slots - 1), do: reg(:"meta_e_#{i}", dgw, reset: nil)

      # -- output ----------------------------------------------------------------------------
      o_active = reg(:o_active, 1)
      o_idx = reg(:o_idx, aw, reset: nil)
      rp = reg(:rp, sb + 1)
      v1o = reg(:v1o, 1)
      last1o = reg(:last1o, 1, reset: nil)
      f1 = reg(:f1, 1, reset: nil)
      e1 = reg(:e1, dgw, reset: nil)

      dmem = memory(:data_ram, width: m, depth: B.bsl(slots, aw), style: :block)
      emem = memory(:err_ram, width: m, depth: B.bsl(slots, aw), style: :block)

      # -- input side ------------------------------------------------------------------------
      full = wire(:full, sub_wrap(wp, rp) == slots)
      bm_idle = wire(:bm_idle, bs == 0)
      bm_load = wire(:bm_load, syn_pend and bm_idle)
      s.tready <~ (not full and (not syn_pend or bm_idle))
      acc = wire(:acc, s.tvalid and s.tready)
      last_in = wire(:last_in, a_idx == len - 1)

      write_port(dmem, addr: cat([wp[0..(sb - 1)], a_idx]), data: sym, en: acc and a_idx < msg)

      sync do
        if acc do
          for {sr, i} <- Enum.with_index(syn) do
            prev = mux(a_idx == 0, 0, sr)
            sr <~ bxor(GF.const_mul(f, prev, root.(fcr + i)), sym)
          end

          a_idx <~ mux(last_in, 0, trunc(a_idx + 1, aw))
          if last_in, do: wp <~ add_wrap(wp, 1)
        end

        if bm_load, do: syn_pend <~ 0
        if acc and last_in, do: syn_pend <~ 1
      end

      # -- Berlekamp-Massey --------------------------------------------------------------------
      bs_iter = wire(:bs_iter, bs == 1)
      bs_rep = wire(:bs_rep, bs == 2)
      bs_done = wire(:bs_done, bs == 3)

      lanes =
        for i <- 0..t do
          x = mux(ph == 1, Enum.at(bb, i), Enum.at(lam, i))
          y = mux(ph == 0, Enum.at(w, i), mux(ph == 1, d, gamma))
          wire(:"prod_#{i}", GF.mul_expr(f, x, y))
        end

      dsum = wire(:dsum, GF.xor_all(lanes))
      upd = wire(:upd, d != 0 and (l <<< 1) <= r)
      ovf = wire(:ovf, l > t)

      deg =
        wire(
          :deg,
          Enum.reduce(0..t, rtl(do: const(0, dgw)), fn i, acc ->
            mux(Enum.at(lam, i) != 0, i, acc)
          end)
        )

      chien_free = wire(:chien_free, not cz_active or cz_idx == 0)
      handoff = wire(:handoff, bs_done and chien_free)

      shift_window = fn ->
        for i <- 1..t, do: Enum.at(w, i) <~ Enum.at(w, i - 1)
        Enum.at(w, 0) <~ Enum.at(q, 0)
        for i <- 0..(np - 2), do: Enum.at(q, i) <~ Enum.at(q, i + 1)
        Enum.at(q, np - 1) <~ Enum.at(q, 0)
      end

      sync do
        if bm_load do
          bs <~ 1
          ph <~ 0
          r <~ 0
          l <~ 0
          gamma <~ 1
          for i <- 0..t do
            Enum.at(lam, i) <~ if(i == 0, do: 1, else: 0)
            Enum.at(bb, i) <~ if(i == 1, do: 1, else: 0)
            Enum.at(w, i) <~ if(i == 0, do: Enum.at(syn, 0), else: 0)
          end

          for i <- 0..(np - 1), do: Enum.at(q, i) <~ Enum.at(syn, rem(i + 1, np))
        end

        if bs_iter do
          if ph == 0 do
            d <~ dsum
            ph <~ 1
          end

          if ph == 1 do
            for i <- 0..t, do: Enum.at(tt, i) <~ Enum.at(lanes, i)
            ph <~ 2
          end

          if ph == 2 do
            for i <- 0..t, do: Enum.at(lam, i) <~ bxor(Enum.at(lanes, i), Enum.at(tt, i))
            Enum.at(bb, 0) <~ 0

            if upd do
              gamma <~ d
              l <~ trunc(r + 1 - l, lw)
              for i <- 1..t, do: Enum.at(bb, i) <~ Enum.at(lam, i - 1)
            else
              for i <- 1..t, do: Enum.at(bb, i) <~ Enum.at(bb, i - 1)
            end

            shift_window.()
            r <~ trunc(r + 1, rw)
            ph <~ 0

            if r == np - 1 do
              bs <~ 2
              r <~ 0
              for i <- 1..t, do: Enum.at(w, i) <~ 0
            end
          end
        end

        if bs_rep do
          for i <- 0..(np - 2), do: Enum.at(om, i) <~ Enum.at(om, i + 1)
          Enum.at(om, np - 1) <~ dsum
          shift_window.()
          r <~ trunc(r + 1, rw)
          if r == np - 1, do: bs <~ 3
        end

        if handoff, do: bs <~ 0
      end

      # -- Chien search ------------------------------------------------------------------------
      lsum = wire(:lsum, GF.xor_all(cl))
      lodd = wire(:lodd, GF.xor_all(for i <- 1..t//2, do: Enum.at(cl, i)))
      osum = wire(:osum, GF.xor_all(co))
      inv_rom = wire(:inv_rom, mux(p1.a, GF.inverse_table(f)), rom_style: :distributed)

      sync do
        if cz_active do
          for {c, i} <- Enum.with_index(cl), i > 0, do: c <~ GF.const_mul(f, c, root.(-i))
          for {c, i} <- Enum.with_index(co), i > 0, do: c <~ GF.const_mul(f, c, root.(-i))
          if fcr != 0, do: cz_y <~ GF.const_mul(f, cz_y, root.(-fcr))
          cz_idx <~ trunc(cz_idx - 1, aw)
          if cz_idx == 0, do: cz_active <~ 0
        end

        if handoff do
          cz_active <~ 1
          cz_idx <~ len - 1
          cz_deg <~ deg
          cz_ovf <~ ovf
          if fcr != 0, do: cz_y <~ 1
          for i <- 0..t, do: Enum.at(cl, i) <~ Enum.at(lam, i)
          for i <- 0..(np - 1), do: Enum.at(co, i) <~ Enum.at(om, i)
        end

        # stage 1: sums, root test; a = denominator, b = numerator
        p1.v <~ cz_active
        p1.idx <~ cz_idx
        p1.last <~ (cz_idx == 0)
        p1.root <~ (lsum == 0)
        p1.deg <~ cz_deg
        p1.ovf <~ cz_ovf
        p1.a <~ lodd
        p1.b <~ osum
        if fcr != 0, do: p1.y <~ cz_y

        # stage 2: inverse of the denominator; a = inverse, b = numerator
        for fld <- [:v, :idx, :last, :root, :deg, :ovf, :b] do
          Map.fetch!(p2, fld) <~ Map.fetch!(p1, fld)
        end

        p2.a <~ inv_rom
        if fcr != 0, do: p2.y <~ p1.y

        # stage 3: a = numerator * inverse
        for fld <- [:v, :idx, :last, :root, :deg, :ovf] do
          Map.fetch!(p3, fld) <~ Map.fetch!(p2, fld)
        end

        p3.a <~ GF.mul_expr(f, p2.a, p2.b)
        if fcr != 0, do: p3.y <~ p2.y

        # stage 4: a = error value
        for fld <- [:v, :idx, :last, :root, :deg, :ovf] do
          Map.fetch!(p4, fld) <~ Map.fetch!(p3, fld)
        end

        p4.a <~ if(fcr != 0, do: GF.mul_expr(f, p3.a, p3.y), else: p3.a)
      end

      total = wire(:total, rc + p4.root)
      fail = wire(:fail, p4.ovf or total != p4.deg)
      cslot = cp[0..(sb - 1)]

      write_port(emem,
        addr: cat([cslot, p4.idx]),
        data: mux(p4.root, p4.a, 0),
        en: p4.v
      )

      sync do
        if p4.v do
          rc <~ mux(p4.last, 0, trunc(total, rcw))

          if p4.last do
            cp <~ add_wrap(cp, 1)

            for {mf, me, i} <- Enum.zip([meta_f, meta_e, 0..(slots - 1)]) do
              if cslot == i do
                mf <~ fail
                me <~ p4.deg
              end
            end
          end
        end
      end

      # -- output --------------------------------------------------------------------------------
      cur_last = wire(:cur_last, o_active and o_idx == msg - 1)
      rp_n = wire(:rp_n, add_wrap(rp, cur_last))
      can_start = wire(:can_start, (not o_active or cur_last) and cp != rp_n)
      ce = wire(:ce, not v1o or mo.tready)
      rslot = rp[0..(sb - 1)]
      raddr = cat([rslot, o_idx])
      d_rd = read_port(dmem, addr: raddr, en: ce and o_active)
      e_rd = read_port(emem, addr: raddr, en: ce and o_active)

      sync do
        if ce do
          v1o <~ o_active
          last1o <~ cur_last
          f1 <~ mux(rslot, meta_f)
          e1 <~ mux(rslot, meta_e)
          rp <~ rp_n
          o_active <~ ((o_active and not cur_last) or can_start)
          o_idx <~ mux(o_active and not cur_last, trunc(o_idx + 1, aw), 0)
        end
      end

      fixed = wire(:fixed, bxor(d_rd, mux(f1, 0, e_rd)))
      mo.tvalid <~ v1o
      mo.tdata <~ if(dw == m, do: fixed, else: zext(fixed, dw))
      mo.tlast <~ last1o
      mo.tuser <~ cat([not f1 and e1 != 0, f1])
      done = wire(:done, v1o and last1o and mo.tready)
      stat_valid <~ done
      stat_failed <~ (done and f1)
      stat_errors <~ mux(done and not f1, e1, 0)
    end
  end
end
