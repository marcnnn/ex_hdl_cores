defmodule ExHdlCores.AXIS do
  @moduledoc """
  AXI4-Stream plumbing. Every block takes the stream shape as options:
  `data:` bits (default 32, a multiple of 8), `user:`, `id:`, `dest:` bits
  (default 0 = absent), `keep: false` / `last: false` to drop those
  signals. Ports are bundles named `<prefix>_axis_<field>`; single-port
  blocks use `s_axis` / `m_axis`, multi-port ones `s0_axis`, `m1_axis`, ...

  Conventions:

    * Bytes are little endian: byte 0 of a word is `tdata[7:0]`.
    * `tkeep` is contiguous from bit 0 and only the last beat of a packet
      may be partial. `tstrb` is not supported.
    * `tuser`, `tid` and `tdest` are carried per beat. Width converters
      OR the `tuser` of the input beats of an output word (upsizing) or
      repeat it on every output beat (downsizing); `tid`/`tdest` are taken
      from the last input beat of a word.
    * Outputs obey the AXI4-Stream rules: `tvalid` stays high and the
      payload stable until `tready`.

  Blocks: `skid/1`, `upsize/1`, `downsize/1`, `convert/1`, `merge/2`,
  `packet_mux/2`, `broadcast/2`, `demux/2` and, in `ExHdlCores.FIFO`, the stream FIFOs.
  """
  use ExHdl.RTL
  alias ExHdl.RTL.{Builder, Interface}
  alias ExHdlCores.Arbiter

  @shape [:data, :keep, :keep_bits, :last, :id, :dest, :user]

  @doc """
  The stream interface for shape options (see the moduledoc). `keep_bits:`
  overrides the width of `tkeep` (one bit per DWord on a PCIe stream:
  `data: 256, keep_bits: 8`); only blocks that carry `tkeep` along without
  interpreting it (`skid/1` with `kind:`, the FIFOs, `merge/2`,
  `packet_mux/2`, `broadcast/2`, `demux/2`) accept it.
  """
  def iface(opts \\ []) do
    base = opts |> Keyword.take(@shape -- [:keep_bits]) |> Interface.axi_stream()

    case Keyword.get(opts, :keep_bits) do
      nil ->
        base

      k ->
        %{
          base
          | fields:
              for(
                {f, t, d} <- base.fields,
                do: if(f == :tkeep, do: {f, {:u, k}, d}, else: {f, t, d})
              )
        }
    end
  end

  @doc "Shape options contained in `opts`."
  def shape(opts), do: Keyword.take(opts, @shape)

  @doc "`{field, type}` of the payload fields (everything except `tvalid`/`tready`), `tdata` first."
  def payload(%Interface{fields: fields}),
    do: for({f, t, :fwd} <- fields, f != :tvalid, do: {f, t})

  @doc "Total payload bits."
  def payload_width(iface),
    do: iface |> payload() |> Enum.map(fn {_, {_, w}} -> w end) |> Enum.sum()

  @doc "Module name fragment for a shape, e.g. `data32_keep4_last1`."
  def tag(iface) do
    iface
    |> payload()
    |> Enum.map_join("_", fn {f, {_, w}} -> "#{String.replace_prefix("#{f}", "t", "")}#{w}" end)
  end

  @doc false
  def all_of(list), do: Enum.reduce(tl(list), hd(list), fn x, acc -> rtl(do: acc and x) end)

  @doc false
  def any_of(list), do: Enum.reduce(tl(list), hd(list), fn x, acc -> rtl(do: acc or x) end)

  @doc "Concatenates payload fields of a bundle (`tdata` in the low bits)."
  def pack(bundle, iface) do
    iface |> payload() |> Enum.reverse() |> Enum.map(fn {f, _} -> bundle[f] end) |> cat()
  end

  @doc "Splits a packed word back into a field => expression map."
  def unpack(word, iface) do
    {map, _} =
      Enum.reduce(payload(iface), {%{}, 0}, fn {f, {_, w}}, {m, lo} ->
        {Map.put(m, f, word[lo..(lo + w - 1)]), lo + w}
      end)

    map
  end

  @doc "Bytes per beat of the interface."
  def bytes(iface) do
    {_, {_, w}, _} = List.keyfind(iface.fields, :tdata, 0)
    div(w, 8)
  end

  # -- skid buffer / register slice ------------------------------------------------------

  @doc """
  Stream register slice. Ports `s_axis` in, `m_axis` out. Options: the
  shape options and `kind:`

    * `:skid` (default) - skid buffer: all `m_axis` outputs and `s_axis_tready`
      registered, one beat per cycle, no combinational path from
      `m_axis_tready` to `s_axis_tready`.
    * `:forward` - one register stage on `tvalid` and the payload only;
      `s_axis_tready` is combinational from `m_axis_tready`, one beat of
      storage, one beat per cycle.
  """
  def skid(opts \\ []) do
    iface = iface(opts)
    kind = Keyword.get(opts, :kind, :skid)
    payload = payload(iface)

    module "axis_#{kind}_#{tag(iface)}" do
      s = slave(:s_axis, iface)
      m = master(:m_axis, iface)
      out_valid = reg(:out_valid, 1)
      out = Map.new(payload, fn {f, t} -> {f, reg(:"out_#{f}", t, reset: nil)} end)
      m.tvalid <~ out_valid
      for {f, _} <- payload, do: m[f] <~ out[f]

      case kind do
        :forward ->
          s.tready <~ (m.tready or not out_valid)

          sync do
            if m.tready or not out_valid do
              out_valid <~ s.tvalid
              for {f, _} <- payload, do: out[f] <~ s[f]
            end
          end

        :skid ->
          skid_valid = reg(:skid_valid, 1)
          skid = Map.new(payload, fn {f, t} -> {f, reg(:"skid_#{f}", t, reset: nil)} end)
          s.tready <~ not skid_valid
          take = wire(:take, m.tready or not out_valid)

          sync do
            if take do
              if skid_valid do
                for {f, _} <- payload, do: out[f] <~ skid[f]
                skid_valid <~ 0
              else
                out_valid <~ s.tvalid
                for {f, _} <- payload, do: out[f] <~ s[f]
              end
            else
              if s.tvalid and not skid_valid do
                for {f, _} <- payload, do: skid[f] <~ s[f]
                skid_valid <~ 1
              end
            end
          end
      end
    end
  end

  # -- width converters ------------------------------------------------------------------

  @doc """
  Width converter between `in_bytes` and `out_bytes` per beat (one an
  integer multiple of the other); shape options as usual with `data`
  ignored. Dispatches to `upsize/1` or `downsize/1`; equal widths give a
  `skid/1`.
  """
  def convert(opts) do
    {i, o} = {Keyword.fetch!(opts, :in_bytes), Keyword.fetch!(opts, :out_bytes)}

    cond do
      i == o -> skid(Keyword.put(opts, :data, 8 * i))
      i < o -> upsize(opts)
      true -> downsize(opts)
    end
  end

  defp ratio!(a, b) do
    unless rem(b, a) == 0 and a >= 1,
      do: raise(ArgumentError, "widths #{a} and #{b} bytes are not an integer ratio")

    div(b, a)
  end

  defp conv_ifaces(opts) do
    {i, o} = {Keyword.fetch!(opts, :in_bytes), Keyword.fetch!(opts, :out_bytes)}
    shape = opts |> shape() |> Keyword.drop([:data]) |> Keyword.merge(keep: true, last: true)
    {iface([{:data, 8 * i} | shape]), iface([{:data, 8 * o} | shape]), i, o}
  end

  @doc """
  Upsizing converter: packs `k = out_bytes / in_bytes` input beats into one
  output beat (little endian, first beat in the low bytes). A packet ends
  with a partial word whose `tkeep` marks the filled bytes. Options:
  `in_bytes:`, `out_bytes:`, shape (`user:`, `id:`, `dest:`). `s_axis_tready`
  depends combinationally on `m_axis_tready`; outputs are registered.
  """
  def upsize(opts) do
    {si, mi, ib, ob} = conv_ifaces(opts)
    k = ratio!(ib, ob)
    side = payload(si) |> Enum.reject(fn {f, _} -> f in [:tdata, :tkeep, :tlast] end)
    cw = Builder.ceil_log2(k)

    module "axis_upsize_#{ib}to#{ob}_#{tag(si)}" do
      s = slave(:s_axis, si)
      m = master(:m_axis, mi)

      ov = reg(:out_valid, 1)
      od = reg(:out_data, 8 * ob)
      ok = reg(:out_keep, ob)
      ol = reg(:out_last, 1)
      oside = Map.new(side, fn {f, t} -> {f, reg(:"out_#{f}", t)} end)
      # accumulator: one slot per input beat, cleared after each output word
      slots = for i <- 0..(k - 1), do: reg(:"acc_data#{i}", 8 * ib)
      keeps = for i <- 0..(k - 1), do: reg(:"acc_keep#{i}", ib)
      idx = reg(:idx, cw)
      acc_side = Map.new(side, fn {f, t} -> {f, reg(:"acc_#{f}", t)} end)

      m.tvalid <~ ov
      m.tdata <~ od
      m.tkeep <~ ok
      m.tlast <~ ol
      for {f, _} <- side, do: m[f] <~ oside[f]
      s.tready <~ (m.tready or not ov)

      take = wire(:take, s.tvalid and (m.tready or not ov))
      finish = wire(:finish, idx == k - 1 or s.tlast)

      word_data = for i <- 0..(k - 1), do: mux(idx == i, s.tdata, Enum.at(slots, i))
      word_keep = for i <- 0..(k - 1), do: mux(idx == i, s.tkeep, Enum.at(keeps, i))

      sync do
        if m.tready, do: ov <~ 0

        if take do
          if finish do
            ov <~ 1
            od <~ cat(Enum.reverse(word_data))
            ok <~ cat(Enum.reverse(word_keep))
            ol <~ s.tlast

            for {f, _} <- side do
              v = if f in [:tid, :tdest], do: s[f], else: acc_side[f] ||| s[f]
              oside[f] <~ v
            end

            for r <- slots ++ keeps, do: r <~ 0
            for {f, _} <- side, do: acc_side[f] <~ 0
            idx <~ 0
          else
            for i <- 0..(k - 1) do
              if idx == i do
                Enum.at(slots, i) <~ s.tdata
                Enum.at(keeps, i) <~ s.tkeep
              end
            end

            for {f, _} <- side do
              v = if f in [:tid, :tdest], do: s[f], else: acc_side[f] ||| s[f]
              acc_side[f] <~ v
            end

            idx <~ add_wrap(idx, 1)
          end
        end
      end
    end
  end

  @doc """
  Downsizing converter: splits each input beat into `k = in_bytes /
  out_bytes` output beats (low bytes first). Slices after the last
  non-empty one of a partial last word are skipped, `tlast` goes on the
  last non-empty slice. Options as for `upsize/1`. The input beat is held
  in registers, `s_axis_tready` depends combinationally on
  `m_axis_tready`, `m_axis` outputs are combinational from the registers.
  """
  def downsize(opts) do
    {si, mi, ib, ob} = conv_ifaces(opts)
    k = ratio!(ob, ib)
    side = payload(si) |> Enum.reject(fn {f, _} -> f in [:tdata, :tkeep, :tlast] end)
    cw = Builder.ceil_log2(k)

    module "axis_downsize_#{ib}to#{ob}_#{tag(si)}" do
      s = slave(:s_axis, si)
      m = master(:m_axis, mi)

      hv = reg(:hold_valid, 1)
      hd = reg(:hold_data, 8 * ib, reset: nil)
      hk = reg(:hold_keep, ib, reset: nil)
      hl = reg(:hold_last, 1, reset: nil)
      hside = Map.new(side, fn {f, t} -> {f, reg(:"hold_#{f}", t, reset: nil)} end)
      idx = reg(:idx, max(cw, 1))

      slice = fn r, w, i -> r[(i * w)..(i * w + w - 1)] end
      pick = fn r, w -> mux(idx, for(i <- 0..(k - 1), do: slice.(r, w, i))) end

      # is there another non-empty slice after the current one?
      more =
        mux(
          idx,
          for(
            i <- 0..(k - 1),
            do: if(i == k - 1, do: const(0, 1), else: slice.(hk, ob, i + 1)[0])
          )
        )

      final = wire(:last_slice, not more)

      m.tvalid <~ hv
      m.tdata <~ pick.(hd, 8 * ob)
      m.tkeep <~ pick.(hk, ob)
      m.tlast <~ (hl and final)
      for {f, _} <- side, do: m[f] <~ hside[f]

      last_out = wire(:last_out, final and m.tready and hv)
      s.tready <~ (not hv or last_out)

      sync do
        if hv and m.tready do
          if final, do: idx <~ 0, else: idx <~ add_wrap(idx, 1)
        end

        if last_out, do: hv <~ 0

        if s.tvalid and (not hv or last_out) do
          hv <~ 1
          hd <~ s.tdata
          hk <~ s.tkeep
          hl <~ s.tlast
          for {f, _} <- side, do: hside[f] <~ s[f]
        end
      end
    end
  end

  # -- merge, broadcast, demux -----------------------------------------------------------

  defp port(prefix, i), do: :"#{prefix}#{i}_axis"

  @doc """
  Merges `n` streams into one: `s0_axis` ... `s<n-1>_axis` in, `m_axis`
  out, combinational apart from the grant lock. Options: shape, `packet:`
  (default true: the grant is held until `tlast`, so packets are not
  interleaved; false: arbitrated per beat), `arbiter:` `:round_robin`
  (default) or `:fixed`. The grant is held from its first cycle until the
  beat (or packet) is accepted, so `m_axis` never changes while stalled.
  """
  def merge(n, opts \\ []) when n >= 1 do
    iface = iface(opts)
    packet = Keyword.get(opts, :packet, true)
    kind = Keyword.get(opts, :arbiter, :round_robin)

    arb =
      if kind == :fixed,
        do: Arbiter.fixed(n, hold: :packet, ports: []),
        else: Arbiter.round_robin(n, hold: :packet, ports: [])

    payload = payload(iface)

    module "axis_merge#{n}_#{kind}#{if packet, do: "_pkt", else: ""}_#{tag(iface)}" do
      ss = for i <- 0..(n - 1), do: slave(port("s", i), iface)
      m = master(:m_axis, iface)
      # unused arbiter outputs would not lint, see NEEDS.md
      a = instance(:arb, arb)
      a.req <~ cat(for s <- Enum.reverse(ss), do: s.tvalid)
      g = a.grant

      for {f, {_, w}} <- payload do
        m[f]
        <~ Enum.reduce(Enum.with_index(ss), nil, fn {s, i}, acc ->
          term = s[f] &&& rep(g[i], w)

          case acc do
            nil -> term
            _ -> acc ||| term
          end
        end)
      end

      sel_valid =
        wire(:sel_valid, reduce_or(a.grant &&& cat(for s <- Enum.reverse(ss), do: s.tvalid)))

      m.tvalid <~ sel_valid
      for {s, i} <- Enum.with_index(ss), do: s.tready <~ (g[i] and m.tready)
      moved = wire(:moved, sel_valid and m.tready)
      a.adv <~ if(packet and iface_last?(iface), do: moved and m.tlast, else: moved)
    end
  end

  @doc """
  Packet multiplexer for `n` requesters sharing one stream (the request
  channel of a PCIe core, a DMA port): `s0_axis` ... `s<n-1>_axis` in,
  `m_axis` out. Like `merge/2` in packet mode, plus what the requesters
  need back:

    * `m_axis_src` - index of the requester the beat on `m_axis` came from
    * `done` (n bits) - bit `i` pulses in the cycle the last beat of a
      packet from requester `i` is transferred on `m_axis`

  Once a packet has started it is forwarded to its `tlast`; between
  packets requesters take turns (`arbiter: :round_robin`, default) or
  requester 0 wins (`:fixed`). Options: shape (`last` is required),
  `arbiter:`, `src:` (default true; false omits the `m_axis_src` port, an
  unread output of an instance does not lint), `register:` (default true: a skid buffer on the output so
  the grant does not depend combinationally on `m_axis_tready`; false:
  none, `s*_axis_tready` follows `m_axis_tready`).

  `ExPcie.RTL.RqMux` is `packet_mux(2, data: 256, keep_bits: 8, user: 62)` with
  `done[1]` as its `b_done`.
  """
  def packet_mux(n, opts \\ []) when n >= 1 do
    iface = iface(opts)
    kind = Keyword.get(opts, :arbiter, :round_robin)
    register = Keyword.get(opts, :register, true)
    src? = Keyword.get(opts, :src, true)
    unless iface_last?(iface), do: raise(ArgumentError, "mux works on packets: needs tlast")
    payload = payload(iface)
    uw = Keyword.get(opts, :user, 0)
    iw = max(Builder.ceil_log2(n), 1)
    ports = [:idx]

    arb =
      if kind == :fixed,
        do: Arbiter.fixed(n, hold: :packet, ports: ports),
        else: Arbiter.round_robin(n, hold: :packet, ports: ports)

    # the source index travels through the register slice in the top bits of tuser
    sk = skid(Keyword.put(shape(opts), :user, uw + iw))

    module "axis_packet_mux#{n}_#{kind}#{if register, do: "_reg", else: ""}#{if src?, do: "", else: "_nosrc"}_#{tag(iface)}" do
      ss = for i <- 0..(n - 1), do: slave(port("s", i), iface)
      m = master(:m_axis, iface)
      src_o = if src?, do: output(:m_axis_src, iw)
      src = wire(:src_w, iw)
      done = output(:done, n)
      a = instance(:arb, arb)
      a.req <~ cat(for s <- Enum.reverse(ss), do: s.tvalid)
      g = a.grant

      sel =
        for {f, {_, w}} <- payload, into: %{} do
          {f,
           Enum.reduce(Enum.with_index(ss), nil, fn {s, i}, acc ->
             term = s[f] &&& rep(g[i], w)
             if is_nil(acc), do: term, else: acc ||| term
           end)}
        end

      sel_valid =
        wire(:sel_valid, reduce_or(a.grant &&& cat(for s <- Enum.reverse(ss), do: s.tvalid)))

      out_ready =
        if register do
          k = instance(:sk, sk)
          k.s_axis.tvalid <~ sel_valid

          for {f, _} <- payload, f != :tuser, do: k.s_axis[f] <~ sel[f]

          k.s_axis.tuser <~ if(uw > 0, do: cat([a.idx, sel.tuser]), else: a.idx)

          k.m_axis.tready <~ m.tready
          m.tvalid <~ k.m_axis.tvalid

          for {f, _} <- payload, f != :tuser, do: m[f] <~ k.m_axis[f]

          if uw > 0, do: m.tuser <~ k.m_axis.tuser[0..(uw - 1)]
          src <~ k.m_axis.tuser[uw..(uw + iw - 1)]
          k.s_axis.tready
        else
          m.tvalid <~ sel_valid
          for {f, _} <- payload, do: m[f] <~ sel[f]
          src <~ a.idx
          m.tready
        end

      for {s, i} <- Enum.with_index(ss), do: s.tready <~ (g[i] and out_ready)
      moved = wire(:moved, sel_valid and out_ready)
      a.adv <~ (moved and sel.tlast)

      case src_o do
        nil -> nil
        o -> o <~ src
      end

      fin = wire(:fin, m.tvalid and m.tready and m.tlast)
      done <~ cat(for i <- (n - 1)..0//-1, do: fin and src == i)
    end
  end

  defp iface_last?(iface), do: List.keymember?(iface.fields, :tlast, 0)

  @doc """
  Broadcasts one stream to `n`: `s_axis` in, `m0_axis` ... `m<n-1>_axis`
  out. A beat is accepted when every output has taken it (outputs that
  were ready earlier are not offered it twice). Options: shape.
  """
  def broadcast(n, opts \\ []) when n >= 1 do
    iface = iface(opts)
    payload = payload(iface)

    module "axis_broadcast#{n}_#{tag(iface)}" do
      s = slave(:s_axis, iface)
      ms = for i <- 0..(n - 1), do: master(port("m", i), iface)
      done = for i <- 0..(n - 1), do: reg(:"done#{i}", 1)

      for {m, d} <- Enum.zip(ms, done) do
        m.tvalid <~ (s.tvalid and not d)
        for {f, _} <- payload, do: m[f] <~ s[f]
      end

      all_ready =
        wire(
          :all_ready,
          all_of(for {m, d} <- Enum.zip(ms, done), do: m.tready or d)
        )

      s.tready <~ all_ready

      sync do
        for {m, d} <- Enum.zip(ms, done) do
          if s.tvalid and all_ready do
            d <~ 0
          else
            if m.tvalid and m.tready, do: d <~ 1
          end
        end
      end
    end
  end

  @doc """
  Routes packets by `tdest`: `s_axis` in, `m0_axis` ... `m<n-1>_axis`
  out. Needs `dest:` bits. Options: shape, `dests:` the `tdest` value of each
  output (default `0..n-1`), `drop_unknown:` (default true: packets with
  another `tdest` are accepted and discarded; false: they stall). The
  `tdest` of the first beat routes the whole packet. Combinational apart
  from the packet lock.
  """
  def demux(n, opts \\ []) when n >= 1 do
    iface = iface(opts)
    dests = Keyword.get(opts, :dests, Enum.to_list(0..(n - 1)))
    drop = Keyword.get(opts, :drop_unknown, true)
    payload = payload(iface)
    dw = Keyword.get(opts, :dest, 0)

    if dw < 1 or length(dests) != n,
      do: raise(ArgumentError, "demux needs dest: bits and one tdest per output")

    module "axis_demux#{n}_#{Enum.join(dests, "_")}#{if drop, do: "", else: "_stall"}_#{tag(iface)}" do
      s = slave(:s_axis, iface)
      ms = for i <- 0..(n - 1), do: master(port("m", i), iface)
      in_pkt = reg(:in_pkt, 1)
      dest_q = reg(:dest_q, dw, reset: nil)
      dest = wire(:dest, mux(in_pkt, dest_q, s.tdest))
      hits = for d <- dests, do: dest == d
      known = wire(:known, any_of(hits))

      for {m, h} <- Enum.zip(ms, hits) do
        m.tvalid <~ (s.tvalid and h)
        for {f, _} <- payload, do: m[f] <~ s[f]
      end

      ready =
        Enum.reduce(Enum.zip(ms, hits), if(drop, do: not known, else: false), fn {m, h}, acc ->
          acc or (h and m.tready)
        end)

      s.tready <~ ready

      sync do
        if s.tvalid and s.tready do
          if s.tlast do
            in_pkt <~ 0
          else
            in_pkt <~ 1
            dest_q <~ dest
          end
        end
      end
    end
  end
end
