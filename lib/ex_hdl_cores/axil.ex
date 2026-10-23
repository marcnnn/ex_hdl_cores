defmodule ExHdlCores.AXIL do
  @moduledoc """
  AXI4-Lite plumbing, 32-bit data, bundles from `ExHdl.RTL.Interface.axi_lite/1`.

    * `cfg_bridge/1` - AXI4-Lite slave to a plain write bus
      (`cfg_we`, `cfg_sel`, `cfg_addr`, `cfg_data`) plus an optional read
      bus; the bus ex_aes67 and ex_net's classifier use.
    * `interconnect/2` - one AXI4-Lite master to `n` slaves by address
      range, e.g. several `ExHdl.Regs` slaves behind one PCIe BAR.

  Both accept one transaction at a time per direction and keep their
  outputs stable under backpressure.
  """
  use ExHdl.RTL
  alias ExHdl.RTL.Builder

  # -- cfg bus bridge --------------------------------------------------------------------

  @doc """
  AXI4-Lite slave to a simple configuration bus in one clock domain.

  The AXI byte address is `{sel, addr, 2'b00}`: bits 1:0 are ignored,
  `addr` is a word address of `addr_bits` bits, `sel` (`sel_bits` bits, 0
  for none) selects a region above it. The slave bundle `s_axil` has
  `sel_bits + addr_bits + 2` address bits.

  Write bus (registered, high for one cycle per write): `cfg_we`,
  `cfg_sel` (with `sel_bits > 0`), `cfg_addr`, `cfg_data` (32), and `cfg_be`
  (4, with `be: true`; without it `wstrb` is ignored and the whole word is
  written). The write response is OKAY, one cycle after the write pulse.

  Read bus (`read: true`, default): `cfg_re` (pulse), `cfg_rsel`,
  `cfg_raddr` (the low `raddr_bits` of the word address, default
  `addr_bits`), and the input `cfg_rdata` (32), which the target must
  provide `rd_latency` cycles after the `cfg_re` cycle (default 1: a
  synchronous RAM addressed by `cfg_raddr`; 0: combinational). Targets
  that are write-only return 0. Read response OKAY. With `read: false`
  reads complete immediately with 0.

  Reads and writes alternate when both wait. A write takes 2 cycles from
  the handshake to its response, a read `rd_latency + 3`.

  ex_aes67's depacketiser (`cfg_sel` 2 bits, `cfg_addr` 16, `stat_addr`
  `idx_w` bits, `stat_lane` 3):

      AXIL.cfg_bridge(sel_bits: 2, addr_bits: 16, raddr_bits: idx_w + 3)
      # stat_addr = cfg_raddr[3..], stat_lane = cfg_raddr[0..2], stat_data -> cfg_rdata

  ex_net's classifier (`cfg_we`, `cfg_addr`, `cfg_data`, no select):

      AXIL.cfg_bridge(sel_bits: 0, addr_bits: addr_w, read: false)
  """
  def cfg_bridge(opts \\ []) do
    ab = Keyword.get(opts, :addr_bits, 16)
    sb = Keyword.get(opts, :sel_bits, 0)
    be? = Keyword.get(opts, :be, false)
    read? = Keyword.get(opts, :read, true)
    rb = Keyword.get(opts, :raddr_bits, ab)
    lat = Keyword.get(opts, :rd_latency, 1)
    aw = sb + ab + 2

    unless ab >= 1 and sb >= 0 and rb in 1..ab and lat >= 0,
      do: raise(ArgumentError, "bad cfg_bridge options")

    name =
      "axil_cfg_s#{sb}_a#{ab}#{if be?, do: "_be", else: ""}" <>
        if(read?, do: "_r#{rb}_l#{lat}", else: "_wo")

    module name do
      s = slave(:s_axil, Interface.axi_lite(addr: aw, data: 32))
      we = output(:cfg_we, 1, reset: 0)
      sel = if sb > 0, do: output(:cfg_sel, sb, reset: 0)
      addr = output(:cfg_addr, ab, reset: 0)
      data = output(:cfg_data, 32, reset: 0)
      be = if be?, do: output(:cfg_be, 4, reset: 0)

      bvalid = reg(:bvalid_r, 1)
      prio_rd = reg(:prio_rd, 1)
      busy = if read?, do: reg(:rd_busy, 1), else: const(0, 1)
      idle = wire(:idle, not bvalid and not busy)

      take_w =
        if read?,
          do: wire(:take_w, idle and s.awvalid and s.wvalid and (not s.arvalid or prio_rd)),
          else: wire(:take_w, idle and s.awvalid and s.wvalid)

      if read? do
        re = output(:cfg_re, 1, reset: 0)
        rsel = if sb > 0, do: output(:cfg_rsel, sb, reset: 0)
        raddr = output(:cfg_raddr, rb, reset: 0)
        rdata_in = input(:cfg_rdata, 32)
        rvalid = reg(:rvalid_r, 1)
        rdata = reg(:rdata_r, 32)
        take_r = wire(:take_r, idle and s.arvalid and not take_w)

        # delay line: stage 0 is `cfg_re` itself, data is due when stage `lat` is high
        pipe = for i <- 1..lat//1, do: reg(:"rd_pipe#{i}", 1)
        due = if lat == 0, do: re, else: List.last(pipe)

        sync do
          re <~ 0
          for {p, prev} <- Enum.zip(pipe, [re | pipe]), do: p <~ prev

          if take_r do
            re <~ 1
            raddr <~ s.araddr[2..(rb + 1)]
            if sb > 0, do: rsel <~ s.araddr[(ab + 2)..(aw - 1)]
            busy <~ 1
            prio_rd <~ 0
          end

          if due do
            rdata <~ rdata_in
            rvalid <~ 1
          end

          if rvalid and s.rready do
            rvalid <~ 0
            busy <~ 0
          end
        end

        s.arready <~ take_r
        s.rvalid <~ rvalid
        s.rdata <~ rdata
        s.rresp <~ 0
      else
        # no read bus: reads complete at once with 0
        rv = reg(:rvalid_r, 1)
        s.arready <~ not rv
        s.rvalid <~ rv
        s.rdata <~ 0
        s.rresp <~ 0

        sync do
          if s.arvalid and not rv do
            rv <~ 1
          else
            if s.rready, do: rv <~ 0
          end
        end
      end

      s.awready <~ take_w
      s.wready <~ take_w
      s.bvalid <~ bvalid
      s.bresp <~ 0

      sync do
        we <~ 0

        if take_w do
          we <~ 1
          addr <~ s.awaddr[2..(ab + 1)]
          if sb > 0, do: sel <~ s.awaddr[(ab + 2)..(aw - 1)]
          data <~ s.wdata
          if be?, do: be <~ s.wstrb
          bvalid <~ 1
          prio_rd <~ 1
        end

        if bvalid and s.bready, do: bvalid <~ 0
      end
    end
  end

  # -- interconnect ----------------------------------------------------------------------

  @doc """
  One AXI4-Lite master to `n` slaves by address range.

  `slaves` is a list of `%{base: b, size: s}` (or `{b, s}`): `size` a power
  of two of at least 4 bytes, `base` a multiple of `size`, ranges disjoint
  and inside the master's address space. Ports: `s_axil` (the master side
  of the system, address bits `addr_bits`, default the smallest that
  covers every range) and `m0_axil` ... `m<n-1>_axil`, each with
  `log2(size)` address bits carrying the offset inside the range, so a
  `defregs` slave with `addr_width` `log2(size)` plugs in directly.

  Protocol: the route of a write is chosen when `awvalid` is first seen
  and held until its response; `awvalid`, `wvalid` and `bready` reach only
  the selected slave. Reads likewise. A write and a read may be in flight
  at the same time (to different slaves or the same one); each direction
  has one transaction at a time. Addresses outside every range complete
  inside the interconnect with `unmapped:` `:decerr` (default, response 3)
  or `:slverr` (2), reads return 0. The combinational path from a slave's
  `ready` to the master's is one AND-OR level; slaves need no
  registered response, but the interconnect adds up to two cycles of
  latency per transaction.

  Constraint on slaves: they must accept an address handshake without
  waiting for a later `bready`/`rready` of the master (every compliant
  slave does).
  """
  def interconnect(slaves, opts \\ []) do
    slaves = Enum.map(slaves, &norm_slave/1)
    n = length(slaves)
    unmapped = Keyword.get(opts, :unmapped, :decerr)
    err = if unmapped == :slverr, do: 2, else: 3
    top = slaves |> Enum.map(&(&1.base + &1.size)) |> Enum.max()
    aw = Keyword.get(opts, :addr_bits, max(Builder.ceil_log2(top), 2))
    check_ranges!(slaves, aw, unmapped)

    name =
      Keyword.get_lazy(opts, :name, fn ->
        "axil_ic_a#{aw}_" <>
          Enum.map_join(slaves, "_", &"#{Integer.to_string(&1.base, 16)}x#{&1.k}") <>
          if(unmapped == :slverr, do: "_se", else: "")
      end)

    module name do
      s = slave(:s_axil, Interface.axi_lite(addr: aw, data: 32))

      ms =
        for {sl, i} <- Enum.with_index(slaves),
            do: master(:"m#{i}_axil", Interface.axi_lite(addr: sl.k, data: 32))

      # hit vectors: one bit per slave, bit n = unmapped
      hit = fn addr ->
        hs =
          for sl <- slaves do
            if sl.k >= aw,
              do: const(1, 1),
              else: addr[sl.k..(aw - 1)] == Bitwise.bsr(sl.base, sl.k)
          end

        any = Enum.reduce(hs, const(0, 1), fn h, acc -> acc or h end)
        cat([not any | Enum.reverse(hs)])
      end

      # -- write ------------------------------------------------------------------------
      wbusy = reg(:wbusy, 1)
      aw_done = reg(:aw_done, 1)
      w_done = reg(:w_done, 1)
      wsel = reg(:wsel, n + 1)

      # the latched route selects the slave; the error leg (bit n) answers itself
      aw_ok =
        Enum.reduce(Enum.with_index(ms), wsel[n], fn {m, i}, acc ->
          acc or (wsel[i] and m.awready)
        end)

      w_ok =
        Enum.reduce(Enum.with_index(ms), wsel[n], fn {m, i}, acc ->
          acc or (wsel[i] and m.wready)
        end)

      aw_go = wire(:aw_go, wbusy and not aw_done)
      w_go = wire(:w_go, wbusy and not w_done)
      s.awready <~ (aw_go and aw_ok)
      s.wready <~ (w_go and w_ok)
      both = wire(:both_done, aw_done and w_done)

      for {m, i} <- Enum.with_index(ms) do
        m.awaddr <~ s.awaddr[0..((slaves |> Enum.at(i) |> Map.fetch!(:k)) - 1)]
        m.awprot <~ s.awprot
        m.awvalid <~ (aw_go and wsel[i] and s.awvalid)
        m.wdata <~ s.wdata
        m.wstrb <~ s.wstrb
        m.wvalid <~ (w_go and wsel[i] and s.wvalid)
        m.bready <~ (both and wsel[i] and s.bready)
      end

      b_valid =
        Enum.reduce(Enum.with_index(ms), wsel[n], fn {m, i}, acc ->
          acc or (wsel[i] and m.bvalid)
        end)

      s.bvalid <~ (both and b_valid)

      s.bresp
      <~ Enum.reduce(Enum.with_index(ms), mux(wsel[n], const(err, 2), const(0, 2)), fn {m, i},
                                                                                       acc ->
        acc ||| (m.bresp &&& rep(wsel[i], 2))
      end)

      sync do
        if not wbusy do
          if s.awvalid do
            wbusy <~ 1
            wsel <~ hit.(s.awaddr)
          end
        else
          if aw_go and aw_ok and s.awvalid, do: aw_done <~ 1
          if w_go and w_ok and s.wvalid, do: w_done <~ 1

          if both and b_valid and s.bready do
            wbusy <~ 0
            aw_done <~ 0
            w_done <~ 0
          end
        end
      end

      # -- read -------------------------------------------------------------------------
      rbusy = reg(:rbusy, 1)
      ar_done = reg(:ar_done, 1)
      rsel = reg(:rsel, n + 1)
      ar_go = wire(:ar_go, rbusy and not ar_done)

      ar_ok =
        Enum.reduce(Enum.with_index(ms), rsel[n], fn {m, i}, acc ->
          acc or (rsel[i] and m.arready)
        end)

      s.arready <~ (ar_go and ar_ok)

      for {m, i} <- Enum.with_index(ms) do
        m.araddr <~ s.araddr[0..((slaves |> Enum.at(i) |> Map.fetch!(:k)) - 1)]
        m.arprot <~ s.arprot
        m.arvalid <~ (ar_go and rsel[i] and s.arvalid)
        m.rready <~ (ar_done and rsel[i] and s.rready)
      end

      r_valid =
        Enum.reduce(Enum.with_index(ms), rsel[n], fn {m, i}, acc ->
          acc or (rsel[i] and m.rvalid)
        end)

      s.rvalid <~ (ar_done and r_valid)

      s.rdata
      <~ Enum.reduce(Enum.with_index(ms), const(0, 32), fn {m, i}, acc ->
        acc ||| (m.rdata &&& rep(rsel[i], 32))
      end)

      s.rresp
      <~ Enum.reduce(Enum.with_index(ms), mux(rsel[n], const(err, 2), const(0, 2)), fn {m, i},
                                                                                       acc ->
        acc ||| (m.rresp &&& rep(rsel[i], 2))
      end)

      sync do
        if not rbusy do
          if s.arvalid do
            rbusy <~ 1
            rsel <~ hit.(s.araddr)
          end
        else
          if ar_go and ar_ok and s.arvalid, do: ar_done <~ 1

          if ar_done and r_valid and s.rready do
            rbusy <~ 0
            ar_done <~ 0
          end
        end
      end
    end
  end

  defp norm_slave({b, s}), do: norm_slave(%{base: b, size: s})

  defp norm_slave(%{base: b, size: s} = m) do
    k = Builder.ceil_log2(s)

    unless Bitwise.bsl(1, k) == s and s >= 4 and rem(b, s) == 0,
      do:
        raise(
          ArgumentError,
          "slave #{inspect(m)}: size must be a power of two >= 4 and base a multiple of it"
        )

    Map.put(m, :k, k)
  end

  defp check_ranges!(slaves, aw, _) do
    for s <- slaves,
        s.base + s.size > Bitwise.bsl(1, aw),
        do: raise(ArgumentError, "slave #{inspect(s)} is outside the #{aw} bit address space")

    sorted = Enum.sort_by(slaves, & &1.base)

    for [a, b] <- Enum.chunk_every(sorted, 2, 1, :discard),
        a.base + a.size > b.base,
        do: raise(ArgumentError, "address ranges overlap: #{inspect(a)} and #{inspect(b)}")
  end
end
