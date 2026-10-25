defmodule ExHdlCores.ConvInterleaver do
  @moduledoc """
  Forney convolutional interleaver and deinterleaver for byte streams, one
  byte per clock, the delay lines in one memory.

  Bytes cycle through `branches` (I) branches. Branch `j` delays by `j * depth`
  (M) bytes of its own sequence when interleaving and by `(I - 1 - j) * M`
  when deinterleaving (`mode: :interleave | :deinterleave`), as
  `ExSdr.Comm.ConvInterleaver`; DVB uses I = 12, M = 17 (`ExHdlCores.DVBT.OuterDecoder`).
  The delay lines start with zeros.

  Options:

    * `branches:`, `depth:` - I and M (I at least 2)
    * `mode:` - default `:deinterleave`
    * `packet:` - packet length in bytes (a multiple of I in practice, 204
      for DVB); `m_axis_tlast` is set on every `packet`-th byte
    * `framing: true` - `s_axis_tlast` marks the last byte of a packet; the
      branch counter restarts at branch 0 after it and `m_axis_tlast`
      repeats it (takes the place of `packet:`)
    * `skip:` - number of output bytes to drop after reset, the zeros of the
      empty delay lines (`I * (I - 1) * M` for a deinterleaver that starts
      on live data, 2244 for DVB)

  Ports: `s_axis` (`tdata` 8, `tlast` with `framing`), `m_axis` (`tdata`,
  `tlast` with `packet:` or `framing`). `s_axis_tready` follows
  `m_axis_tready` combinationally (the whole pipeline advances together).
  Latency one cycle; throughput one byte per clock.

  Structure: a ring buffer per branch in one memory (`sum d_j` bytes), one
  address register per branch. Each byte reads the oldest byte of its ring
  in one cycle and writes itself into that place in the next, so the memory
  never reads and writes one address in a cycle (with `framing` and a ring
  of one byte, the byte being written is forwarded). Branch 0 of a deinterleaver
  (or the last of an interleaver) has no delay and passes straight through.
  """
  use ExHdl.RTL
  alias ExHdl.RTL.Builder
  alias ExHdlCores.AXIS

  @doc "Delay of branch `j` in bytes of that branch."
  def branch_delay(i, m, mode, j), do: if(mode == :interleave, do: j * m, else: (i - 1 - j) * m)

  @doc "Reference: one byte list through the interleaver, delay lines of zeros."
  def model(bytes, i, m, mode \\ :deinterleave) do
    fifos = for j <- 0..(i - 1), into: %{}, do: {j, List.duplicate(0, branch_delay(i, m, mode, j))}

    {out, _} =
      bytes
      |> Enum.with_index()
      |> Enum.map_reduce(fifos, fn {b, n}, fifos ->
        j = rem(n, i)

        case fifos[j] do
          [] -> {b, fifos}
          [o | rest] -> {o, Map.put(fifos, j, rest ++ [b])}
        end
      end)

    out
  end

  def build(opts) do
    i = Keyword.fetch!(opts, :branches)
    m = Keyword.fetch!(opts, :depth)
    mode = Keyword.get(opts, :mode, :deinterleave)
    packet = opts[:packet]
    framing = Keyword.get(opts, :framing, false)
    skip = Keyword.get(opts, :skip, 0)

    unless i >= 2 and m >= 1 and mode in [:interleave, :deinterleave],
      do: raise(ArgumentError, "conv interleaver: branches >= 2, depth >= 1 and a mode")

    delays = for j <- 0..(i - 1), do: branch_delay(i, m, mode, j)
    bases = Enum.scan(delays, 0, &+/2) |> then(&[0 | Enum.drop(&1, -1)])
    total = Enum.sum(delays)
    aw = max(Builder.ceil_log2(total), 1)
    jw = Builder.ceil_log2(i)
    pw = if packet && not framing, do: Builder.ceil_log2(packet), else: 0
    sw = max(Builder.ceil_log2(skip + 1), 1)
    use_last = framing or packet != nil
    # with framing a branch can be hit on consecutive cycles (one byte
    # packets); only a ring of one byte then reads the address being written
    forward = framing and 1 in delays
    s_iface = AXIS.iface(data: 8, keep: false, last: framing)
    m_iface = AXIS.iface(data: 8, keep: false, last: use_last)

    tag =
      "#{if mode == :interleave, do: "i", else: "d"}#{i}x#{m}" <>
        if(framing, do: "_f", else: if(packet, do: "_p#{packet}", else: "")) <>
        if(skip > 0, do: "_s#{skip}", else: "")

    module "conv_#{if mode == :interleave, do: "interleaver", else: "deinterleaver"}_#{tag}" do
      s = slave(:s_axis, s_iface)
      mo = master(:m_axis, m_iface)

      v1 = reg(:v1, 1)
      b1 = reg(:b1, 8, reset: nil)
      a1 = reg(:a1, aw, reset: nil)
      byp1 = reg(:byp1, 1, reset: nil)
      fwd1 = if forward, do: reg(:fwd1, 1, reset: nil)
      fdat1 = if forward, do: reg(:fdat1, 8, reset: nil)
      last1 = if use_last, do: reg(:last1, 1, reset: nil)
      skip_cnt = if skip > 0, do: reg(:skip_cnt, sw, reset: skip)
      branch = reg(:branch, max(jw, 1))
      pos = if pw > 0, do: reg(:pos, pw)

      addrs =
        for {d, base} <- Enum.zip(delays, bases),
            do: if(d > 0, do: reg(:"addr_#{base}", aw, reset: base))

      mem = if total > 0, do: memory(:ring, width: 8, depth: max(total, 2), style: :auto)

      skipping = if skip > 0, do: wire(:skipping, skip_cnt != 0), else: rtl(do: const(0, 1))
      out_valid = wire(:out_valid, v1 and not skipping)
      ce = wire(:ce, not out_valid or mo.tready)
      acc = wire(:acc, s.tvalid and ce)

      pad = fn list -> list ++ List.duplicate(List.last(list), Integer.pow(2, jw) - length(list)) end

      cur_addr =
        wire(
          :cur_addr,
          mux(
            branch,
            pad.(
              for(
                {a, d} <- Enum.zip(addrs, delays),
                do: if(d > 0, do: a, else: rtl(do: const(0, aw)))
              )
            )
          )
        )

      cur_byp = wire(:cur_byp, mux(branch, pad.(for(d <- delays, do: if(d > 0, do: 0, else: 1)))))

      rd = read_port(mem, addr: cur_addr, en: acc)
      write_port(mem, addr: a1, data: b1, en: ce and v1 and not byp1)

      s.tready <~ ce
      mo.tvalid <~ out_valid
      mo.tdata <~ if(forward, do: mux(byp1, b1, mux(fwd1, fdat1, rd)), else: mux(byp1, b1, rd))
      if use_last, do: mo.tlast <~ last1

      end_of_packet =
        cond do
          framing -> s.tlast
          packet -> pos == packet - 1
          true -> nil
        end

      next_branch =
        wire(:next_branch, mux(branch == i - 1, 0, trunc(branch + 1, max(jw, 1))))

      sync do
        if ce do
          v1 <~ s.tvalid
          b1 <~ s.tdata
          a1 <~ cur_addr
          byp1 <~ cur_byp

          if forward do
            fwd1 <~ (v1 and not byp1 and cur_addr == a1)
            fdat1 <~ b1
          end

          if use_last, do: last1 <~ end_of_packet
          if skip > 0, do: if(v1 and skipping, do: skip_cnt <~ sub_wrap(skip_cnt, 1))
        end

        if acc do
          branch <~ if(framing, do: mux(s.tlast, 0, next_branch), else: next_branch)
          if pw > 0, do: pos <~ mux(end_of_packet, 0, trunc(pos + 1, pw))
        end
      end

      for {a, d, base, j} <- Enum.zip([addrs, delays, bases, 0..(i - 1)]), d > 0 do
        sync do
          if acc and branch == j do
            a <~ mux(a == base + d - 1, base, trunc(a + 1, aw))
          end
        end
      end
    end
  end
end
