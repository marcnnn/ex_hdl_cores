defmodule ExHdlCores.HeaderCapture do
  @moduledoc """
  Captures the first `header:` bytes of every packet of an AXI4-Stream
  into a register while passing the stream through unchanged (no added
  latency: `m_axis` is `s_axis`, `s_axis_tready` is `m_axis_tready`).

  Replaces the capture register of ex_net's `ExNet.RTL.Classifier`
  (`hdr0..hdr11`, the first 12 beats of a 64 bit stream). Not covered: its
  delay line and result ring (a verdict computed from the header and
  attached to the same packet); build that with `ExHdlCores.FIFO.axis/1`
  or a `packet/1` FIFO behind a block that reads `hdr`.

  Ports: `s_axis` / `m_axis` (shape options as `ExHdlCores.AXIS`; `keep`
  and `last` are required), and

    * `hdr` (8 * `header` bits) - the captured bytes, byte 0 of the packet
      in the low bits; bytes not seen (short packet) read 0
    * `hdr_len` (clog2 of `header + 1` bits) - the number of captured
      bytes, at most `header` (from `tkeep`)
    * `hdr_valid` - the capture of the current packet is complete: the
      `header`th byte or `tlast` was accepted. Registered, so it rises one
      cycle after that beat; falls when the first beat of the next packet
      is accepted (it is then low for that packet until its capture ends)
    * `hdr_start` - pulse, one cycle after the first beat of a packet was
      accepted

  `hdr` and `hdr_len` are stable while `hdr_valid` is high. A one beat
  packet gives `hdr_valid` in the cycle after the beat. With a header
  longer than the packet that ends it, `hdr_valid` is high in the cycle
  after `tlast`.

  Options: `header:` bytes (default 64), `name:`, shape options (`data:`
  default 64).
  """
  use ExHdl.RTL
  alias ExHdlCores.AXIS

  @doc "Reference: `{hdr, hdr_len}` for a packet binary and a header size."
  def ref(packet, header) do
    n = min(byte_size(packet), header)
    {packet |> binary_part(0, n) |> :binary.decode_unsigned(:little), n}
  end

  @doc "Capture module; see the moduledoc."
  def build(opts \\ []) do
    header = Keyword.get(opts, :header, 64)
    iface = AXIS.iface(Keyword.merge([data: 64], AXIS.shape(opts)))
    bytes = AXIS.bytes(iface)
    nb = div(header + bytes - 1, bytes)
    lw = ExHdl.RTL.Builder.ceil_log2(header + 1)
    cw = max(lw, ExHdl.RTL.Builder.ceil_log2(bytes + 1)) + 1
    iw = max(ExHdl.RTL.Builder.ceil_log2(nb + 1), 1)
    name = Keyword.get(opts, :name, "hdr_capture_#{header}_#{AXIS.tag(iface)}")

    module name do
      s = slave(:s_axis, iface)
      m = master(:m_axis, iface)
      hdr_o = output(:hdr, 8 * header)
      len_o = output(:hdr_len, lw)
      valid_o = output(:hdr_valid, 1)
      start_o = output(:hdr_start, 1)

      m.tvalid <~ s.tvalid
      s.tready <~ m.tready

      for {f, _} <- AXIS.payload(iface), do: m[f] <~ s[f]

      # beat index in the packet, saturating at nb
      idx = reg(:idx, iw, reset: 0)
      len = reg(:len, lw, reset: 0)
      valid = reg(:valid, 1, reset: 0)
      start = reg(:start, 1, reset: 0)
      hs = for i <- 0..(nb - 1), do: reg(:"h#{i}", 8 * bytes, reset: 0)

      take = wire(:take, s.tvalid and m.tready)
      first = wire(:first, take and idx == 0)
      lasts = wire(:lasts, take and s.tlast)
      full = wire(:full, take and idx == nb - 1)

      # valid bytes of this beat
      kbits = for b <- 0..(bytes - 1), do: s.tkeep[b]
      kmask = wire(:kmask, cat(for k <- Enum.reverse(kbits), _ <- 1..8, do: k))

      cnt =
        Enum.reduce(kbits, const(0, cw), fn k, acc ->
          add_wrap(acc, cat([const(0, cw - 1), k]))
        end)

      base = mux(first, const(0, lw), len)
      total = wire(:total, add_wrap(cat([const(0, cw - lw), base]), cnt))
      capped = wire(:capped, mux(total > header, const(header, cw), total))

      sync do
        start <~ first

        if take do
          idx <~ mux(s.tlast, const(0, iw), mux(idx == nb, idx, add_wrap(idx, 1)))
          if idx < nb, do: len <~ slice(capped, 0, lw)
        end

        if first, do: valid <~ 0
        if lasts or full, do: valid <~ 1

        for {h, i} <- Enum.with_index(hs) do
          if take and idx == i, do: h <~ (s.tdata &&& kmask)
          if first and i > 0, do: h <~ 0
        end
      end

      hdr_o <~ slice(cat(Enum.reverse(hs)), 0, 8 * header)
      len_o <~ len
      valid_o <~ valid
      start_o <~ start
    end
  end
end
