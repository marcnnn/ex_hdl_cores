defmodule ExHdlCores.FIFO do
  @moduledoc """
  FIFOs. All depths are powers of two.

    * `sync_fifo/1` - synchronous FIFO, block, UltraRAM or distributed storage,
      first-word fall-through (FWFT) or registered reads, occupancy `count`,
      optional almost full / almost empty flags.
    * `async_fifo/1` - dual-clock FIFO: Gray-coded pointers through
      `ExHdl.RTL.CDC.sync_ff/1`.
    * `axis/1` and `axis_async/1` - AXI4-Stream FIFOs around those.
    * `packet/1` - store-and-forward packet FIFO that drops packets flagged
      bad in `tuser` (and optionally packets that do not fit).

  ## Reads

  With `fwft: true` (default) `rd_data` shows the oldest entry while
  `empty` is low and `rd_en` pops it. Distributed storage reads
  combinationally; block and UltraRAM storage need a synchronous read, so
  the FIFO prefetches into the RAM's output register: the data appears one
  cycle later than with distributed storage (two cycles after a push into
  an empty FIFO) and the output register holds one more entry than the
  RAM, which `count` includes. With `fwft: false`, `rd_en` pops and
  `rd_data` is valid in the next cycle (`rd_valid`).

  Writes while `full` and reads while `empty` are ignored.

  ## Reset

  `sync_fifo/1` has one synchronous active-low reset (`rst_n`) for pointers and
  counters; the RAM contents are not reset. `async_fifo/1` has `rst_wr_n` in
  the write domain and `rst_rd_n` in the read domain, both synchronous. Assert
  both together and hold them for at least `stages + 1` cycles of the
  slower clock (build them from one asynchronous source with
  `ExHdl.RTL.CDC.reset_sync/1` per domain); do not push or pop until both
  are released. Resetting only one side while the other is operating
  leaves the pointers inconsistent. The synchroniser flip-flops are reset
  as well, so no stale pointer survives the reset.
  """
  use ExHdl.RTL
  alias ExHdl.RTL.{Builder, CDC}
  alias ExHdlCores.AXIS

  defp log2!(depth) do
    aw = Builder.ceil_log2(depth)

    unless depth >= 2 and Bitwise.bsl(1, aw) == depth,
      do: raise(ArgumentError, "FIFO depth must be a power of two, got #{depth}")

    aw
  end

  defp style_tag(style, fwft), do: "#{style}#{if fwft, do: "_fwft", else: ""}"

  # Prefetching read stage for synchronous-read RAM, FWFT: the RAM output
  # register is the output entry. `avail`: the RAM holds an entry at `rptr`
  # that the stage has not fetched. Returns {rd_data, valid, pop, load}.
  @doc false
  def read_stage(mem, rptr, aw, avail, rd_en, domain) do
    rtl do
      valid = reg(:ovalid, 1, domain: domain)
      pop = wire(:pop, rd_en and valid)
      free = wire(:slot_free, not valid or pop)
      load = wire(:load, free and avail)
      rd = read_port(mem, domain: domain, addr: rptr[0..(aw - 1)], en: load)

      sync domain do
        if free, do: valid <~ avail
        if load, do: rptr <~ add_wrap(rptr, 1)
      end

      {rd, valid, pop, load}
    end
  end

  @doc """
  Synchronous FIFO. Options: `width:` (default 8), `depth:` (default 16),
  `style:` `:block` (default), `:ultra`, `:distributed`, `fwft:` (true),
  `almost_full:` n (adds `almost_full`, high when `count >= n`),
  `almost_empty:` n (adds `almost_empty`, high when `count <= n`),
  `count:` (true; false omits the `count` port).

  Ports: `wr_en`, `wr_data`, `full`; `rd_en`, `rd_data`, `empty` (and
  `rd_valid` without `fwft`); `count` (aw + 1 bits, entries stored).
  """
  def sync_fifo(opts \\ []) do
    width = Keyword.get(opts, :width, 8)
    depth = Keyword.get(opts, :depth, 16)
    style = Keyword.get(opts, :style, :block)
    fwft = Keyword.get(opts, :fwft, true)
    af = Keyword.get(opts, :almost_full)
    ae = Keyword.get(opts, :almost_empty)
    counted = Keyword.get(opts, :count, true)
    aw = log2!(depth)

    tag =
      "#{width}x#{depth}_#{style_tag(style, fwft)}#{af && "_af#{af}"}#{ae && "_ae#{ae}"}" <>
        if(counted, do: "", else: "_nc")

    module "fifo_sync_#{tag}" do
      wr_en = input(:wr_en, 1)
      wr_data = input(:wr_data, width)
      full = output(:full, 1)
      rd_en = input(:rd_en, 1)
      rd_data = output(:rd_data, width)
      empty = output(:empty, 1)
      rd_valid = if not fwft, do: output(:rd_valid, 1, reset: 0)
      count = reg(:fill, aw + 1)
      if counted, do: output(:count, aw + 1) <~ count
      almost_full = if af, do: output(:almost_full, 1)
      almost_empty = if ae, do: output(:almost_empty, 1)

      wptr = reg(:wptr, aw + 1)
      rptr = reg(:rptr, aw + 1)
      mem = memory(:mem, width: width, depth: depth, style: style)

      full <~ (count == depth)
      push = wire(:push, wr_en and not full)
      write_port(mem, addr: wptr[0..(aw - 1)], data: wr_data, en: push)

      pop =
        cond do
          fwft and style != :distributed ->
            {rd, valid, pop, _load} = read_stage(mem, rptr, aw, wptr != rptr, rd_en, :sys)
            rd_data <~ rd
            empty <~ not valid
            pop

          fwft ->
            rd_data <~ read_port(mem, kind: :async, addr: rptr[0..(aw - 1)])
            empty <~ (count == 0)
            pop = wire(:pop, rd_en and not empty)
            sync(do: if(pop, do: rptr <~ add_wrap(rptr, 1)))
            pop

          true ->
            empty <~ (count == 0)
            pop = wire(:pop, rd_en and not empty)
            rd_data <~ read_port(mem, addr: rptr[0..(aw - 1)], en: pop)
            sync(do: if(pop, do: rptr <~ add_wrap(rptr, 1)))
            pop
        end

      sync do
        if push, do: wptr <~ add_wrap(wptr, 1)
        if not fwft, do: rd_valid <~ pop

        if push and not pop do
          count <~ add_wrap(count, 1)
        else
          if pop and not push, do: count <~ sub_wrap(count, 1)
        end
      end

      if af, do: almost_full <~ (count >= af)
      if ae, do: almost_empty <~ (count <= ae)
    end
  end

  @doc """
  Asynchronous (dual-clock) FIFO, same read semantics as `sync_fifo/1`
  (see the moduledoc for the reset rules). Options: `width:` (8), `depth:`
  (16), `style:` (`:block`), `count:` (false; adds `wr_count` and
  `rd_count`, the fill level as seen from each side: pessimistic by the
  synchroniser delay, and with block storage `rd_count` includes the
  output register).

  Ports: `clk_wr`, `rst_wr_n`, `wr_en`, `wr_data`, `full` (write domain);
  `clk_rd`, `rst_rd_n`, `rd_en`, `rd_data`, `empty` (read domain). With
  block or UltraRAM storage the FIFO holds `depth + 1` entries: the
  output register is one more.
  """
  def async_fifo(opts \\ []) do
    width = Keyword.get(opts, :width, 8)
    depth = Keyword.get(opts, :depth, 16)
    style = Keyword.get(opts, :style, :block)
    counted = Keyword.get(opts, :count, false)
    aw = log2!(depth)
    fwft_ram = style != :distributed

    module "fifo_async_#{width}x#{depth}_#{style}#{if counted, do: "_c", else: ""}" do
      domain(:wr, clock: :clk_wr, reset: :rst_wr_n)
      domain(:rd, clock: :clk_rd, reset: :rst_rd_n)
      wr_en = input(:wr_en, 1, domain: :wr)
      wr_data = input(:wr_data, width, domain: :wr)
      full = output(:full, 1)
      rd_en = input(:rd_en, 1, domain: :rd)
      rd_data = output(:rd_data, width)
      empty = output(:empty, 1)

      wptr = reg(:wptr, aw + 1, domain: :wr)
      wgray = reg(:wgray, aw + 1, domain: :wr)
      rptr = reg(:rptr, aw + 1, domain: :rd)
      rgray = reg(:rgray, aw + 1, domain: :rd)

      w2r = instance(:w2r, CDC.sync_ff(width: aw + 1, reset: true), domains: [dst: :rd])
      r2w = instance(:r2w, CDC.sync_ff(width: aw + 1, reset: true), domains: [dst: :wr])
      w2r.d <~ wgray
      r2w.d <~ rgray

      mem = memory(:mem, width: width, depth: depth, style: style)

      # write side: full when the write pointer is a lap ahead of the read pointer
      # (Gray code: the top two bits inverted, the rest equal)
      q = r2w.q
      lap = [~~~q[(aw - 1)..aw]] ++ if aw >= 2, do: [q[0..(aw - 2)]], else: []
      full <~ (wgray == cat(lap))
      push = wire(:push, wr_en and not full)
      wnext = wire(:wnext, add_wrap(wptr, push))
      write_port(mem, domain: :wr, addr: wptr[0..(aw - 1)], data: wr_data, en: push)

      sync :wr do
        wptr <~ wnext
        wgray <~ CDC.gray(wnext)
      end

      # read side
      {rnext, held} =
        if fwft_ram do
          avail = wire(:avail, rgray != w2r.q)
          {rd, valid, _pop, load} = read_stage(mem, rptr, aw, avail, rd_en, :rd)
          rd_data <~ rd
          empty <~ not valid
          {wire(:rnext, add_wrap(rptr, load)), valid}
        else
          rd_data <~ read_port(mem, kind: :async, domain: :rd, addr: rptr[0..(aw - 1)])
          empty <~ (rgray == w2r.q)
          pop = wire(:pop, rd_en and not empty)
          {wire(:rnext, add_wrap(rptr, pop)), nil}
        end

      sync :rd do
        if not fwft_ram, do: rptr <~ rnext
        rgray <~ CDC.gray(rnext)
      end

      if counted do
        wr_count = output(:wr_count, aw + 1)
        rd_count = output(:rd_count, aw + 1)
        wr_count <~ sub_wrap(wptr, CDC.ungray(r2w.q))
        level = sub_wrap(CDC.ungray(w2r.q), rptr)
        rd_count <~ if(held, do: add_wrap(level, held), else: level)
      end
    end
  end

  # -- AXI4-Stream ------------------------------------------------------------------------

  defp stream_fifo(name, iface, core, opts) do
    domains = if opts[:async], do: [wr: :wr, rd: :rd], else: []

    module name do
      if opts[:async] do
        domain(:wr, clock: :clk_wr, reset: :rst_wr_n)
        domain(:rd, clock: :clk_rd, reset: :rst_rd_n)
      end

      s = slave(:s_axis, iface, if(opts[:async], do: [domain: :wr], else: []))
      m = master(:m_axis, iface, if(opts[:async], do: [domain: :rd], else: []))
      f = instance(:fifo, core, domains: domains)
      f.wr_en <~ s.tvalid
      f.wr_data <~ AXIS.pack(s, iface)
      s.tready <~ not f.full
      m.tvalid <~ not f.empty
      f.rd_en <~ m.tready
      for {field, e} <- AXIS.unpack(f.rd_data, iface), do: m[field] <~ e

      for {port, w} <- Keyword.get(opts, :extra, []) do
        output(port, w) <~ f[port]
      end
    end
  end

  @doc """
  AXI4-Stream FIFO: `s_axis` in, `m_axis` out, one sync FIFO of the packed
  payload (`tdata`, `tkeep`, `tlast`, `tuser`, ...). Options: the stream shape
  (`ExHdlCores.AXIS`), `depth:` (default 512), `style:` (`:block`),
  `almost_full:`, `almost_empty:` (extra outputs as in `sync_fifo/1`),
  `count:` (adds the `count` output).
  """
  def axis(opts \\ []) do
    iface = AXIS.iface(opts)
    depth = Keyword.get(opts, :depth, 512)
    counted = Keyword.get(opts, :count, false)

    fifo_opts =
      [
        width: AXIS.payload_width(iface),
        depth: depth,
        count: counted
      ] ++
        Keyword.take(opts, [:style, :almost_full, :almost_empty])

    core = sync_fifo(fifo_opts)

    extra =
      for {k, w} <- [count: log2!(depth) + 1, almost_full: 1, almost_empty: 1],
          Enum.any?(core.ports, &(&1.name == k and &1.dir == :output)),
          do: {k, w}

    stream_fifo("axis_fifo_#{AXIS.tag(iface)}_#{core.name}", iface, core, extra: extra)
  end

  @doc """
  Asynchronous AXI4-Stream FIFO: `s_axis` in the write domain (`clk_wr`,
  `rst_wr_n`), `m_axis` in the read domain (`clk_rd`, `rst_rd_n`). Options:
  the stream shape, `depth:` (512), `style:` (`:block`); reset rules as in
  the moduledoc.
  """
  def axis_async(opts \\ []) do
    iface = AXIS.iface(opts)
    depth = Keyword.get(opts, :depth, 512)

    core =
      async_fifo([width: AXIS.payload_width(iface), depth: depth] ++ Keyword.take(opts, [:style]))

    stream_fifo("axis_afifo_#{AXIS.tag(iface)}_#{core.name}", iface, core, async: true)
  end

  @doc """
  Store-and-forward packet FIFO for streams that cannot be stopped (a MAC
  receiver). A packet becomes visible at `m_axis` only after its `tlast`
  beat was stored, and only if `tuser[err_bit]` was low on that beat;
  otherwise the whole packet is dropped and the space reused. Packets are
  never cut: a reader sees complete packets only.

  Options: the stream shape (`user:` at least `err_bit + 1` bits, default 1;
  `data:` default 64), `depth:` beats (default 512), `style:` (`:block`),
  `err_bit:` (0), `drop_on_full:` (default true).

    * `drop_on_full: true` - `s_axis_tready` is always high; a packet that
      does not fit (storage full when a beat arrives) is dropped whole,
      also the rest of it that is still to come.
    * `drop_on_full: false` - `s_axis_tready` is low while the storage is
      full. A packet longer than `depth` then blocks forever: only use it
      when packets are known to fit.

  Ports: `s_axis`, `m_axis`; `drop_bad` and `drop_full` (one-cycle pulses
  when a packet is dropped for its error flag / because it did not fit;
  registered); `level` (beats of complete packets stored, including the
  output register).
  """
  def packet(opts \\ []) do
    opts = Keyword.merge([data: 64, user: 1], opts)
    iface = AXIS.iface(opts)
    depth = Keyword.get(opts, :depth, 512)
    style = Keyword.get(opts, :style, :block)
    err_bit = Keyword.get(opts, :err_bit, 0)
    stall = not Keyword.get(opts, :drop_on_full, true)
    aw = log2!(depth)

    unless err_bit < opts[:user],
      do: raise(ArgumentError, "err_bit #{err_bit} is not a bit of tuser (#{opts[:user]} bits)")

    module "fifo_packet_#{AXIS.tag(iface)}_#{depth}_#{style}_e#{err_bit}#{if stall, do: "_stall", else: ""}" do
      s = slave(:s_axis, iface)
      m = master(:m_axis, iface)
      drop_bad = output(:drop_bad, 1, reset: 0)
      drop_full = output(:drop_full, 1, reset: 0)
      level = output(:level, aw + 1)

      wptr = reg(:wptr, aw + 1)
      wtmp = reg(:wtmp, aw + 1)
      rptr = reg(:rptr, aw + 1)
      dropping = reg(:dropping, 1)
      mem = memory(:mem, width: AXIS.payload_width(iface), depth: depth, style: style)

      full = wire(:full, sub_wrap(wtmp, rptr) == depth)
      if stall, do: s.tready <~ not full, else: s.tready <~ 1
      accept = wire(:accept, s.tvalid and s.tready)
      store = wire(:store, accept and not dropping and not full)
      write_port(mem, addr: wtmp[0..(aw - 1)], data: AXIS.pack(s, iface), en: store)
      bad = s.tuser[err_bit]
      next = wire(:wtmp_next, add_wrap(wtmp, 1))

      sync do
        drop_bad <~ 0
        drop_full <~ 0

        if accept do
          if dropping do
            if s.tlast, do: dropping <~ 0
          else
            if full do
              wtmp <~ wptr
              drop_full <~ 1
              if not s.tlast, do: dropping <~ 1
            else
              if s.tlast and bad do
                wtmp <~ wptr
                drop_bad <~ 1
              else
                wtmp <~ next
                if s.tlast, do: wptr <~ next
              end
            end
          end
        end
      end

      {rd, valid, _pop, _load} = read_stage(mem, rptr, aw, wptr != rptr, m.tready, :sys)
      m.tvalid <~ valid
      for {field, e} <- AXIS.unpack(rd, iface), do: m[field] <~ e
      level <~ add_wrap(sub_wrap(wptr, rptr), valid)
    end
  end
end
