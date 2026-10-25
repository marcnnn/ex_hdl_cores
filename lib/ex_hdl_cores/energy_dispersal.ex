defmodule ExHdlCores.EnergyDispersal do
  @moduledoc """
  DVB energy dispersal (randomiser, ETSI EN 300 744, 4.3.1) as a byte
  stream descrambler, one byte per clock, behaving as
  `ExSdr.DVBT.EnergyDispersal.descramble_at/2` as the receiver uses it.

  The PRBS `1 + x^14 + x^15` is loaded with `100101010000000` at the start
  of every group of 8 transport packets of 188 bytes. It runs through
  every byte of the group except the first sync byte; its output is XORed
  onto all bytes except the 8 sync bytes, which become `0x47` (the first
  one arrives inverted as `0xB8`).

  Packets are delimited by `s_axis_tlast` (188 bytes each). Until
  `0xB8` is seen as the first byte of a packet the stream is not aligned
  and packets are dropped whole, as the receiver does before its first
  group; afterwards the position in the group is counted blindly, the
  sync bytes are not looked at again. `realign` (a pulse) forgets the
  alignment, for a resynchronised upstream.

  Ports: `s_axis` / `m_axis` (`tdata` 8, `tlast`, `tuser` of `user:` bits,
  default none, passed through), `realign`, `aligned` (registered).
  One byte per clock, `s_axis_tready` follows `m_axis_tready`
  combinationally. Latency one cycle.
  """
  use ExHdl.RTL
  alias Bitwise, as: B
  alias ExHdlCores.{AXIS, Scrambler}

  @seed 0b100101010000000

  @doc "Reference: PRBS byte and next state from a 15 bit state (stage 1 is bit 14)."
  def prbs_byte(state, data \\ 0) do
    Enum.reduce(1..8, {state, 0}, fn _, {s, out} ->
      fb = B.bxor(B.band(B.bsr(s, 1), 1), B.band(s, 1))
      {B.bor(B.bsr(s, 1), B.bsl(fb, 14)), B.bor(B.bsl(out, 1), fb)}
    end)
    |> then(fn {s, out} -> {s, B.bxor(out, data)} end)
  end

  @doc "Reference: descramble whole groups from the first inverted sync byte; `packets` is a list of 188 byte binaries, unaligned ones before it are dropped."
  def model(packets) do
    packets
    |> Enum.drop_while(&(:binary.first(&1) != 0xB8))
    |> Enum.with_index()
    |> Enum.map_reduce(@seed, fn {pkt, idx}, lfsr ->
      lfsr = if rem(idx, 8) == 0, do: @seed, else: lfsr
      <<_sync, payload::binary>> = pkt

      {lfsr, out} =
        if rem(idx, 8) == 0,
          do: {lfsr, []},
          else: {elem(prbs_byte(lfsr), 0), []}

      {lfsr, bytes} =
        Enum.reduce(:binary.bin_to_list(payload), {lfsr, out}, fn b, {s, acc} ->
          {s, o} = prbs_byte(s, b)
          {s, [o | acc]}
        end)

      {<<0x47>> <> :binary.list_to_bin(Enum.reverse(bytes)), lfsr}
    end)
    |> elem(0)
  end

  def build(opts \\ []) do
    user = Keyword.get(opts, :user, 0)
    iface = AXIS.iface(data: 8, keep: false, user: user)
    m = Scrambler.matrix(fn s, d -> prbs_byte(s, d) end, 15, 8)

    module "dvb_energy_dispersal_u#{user}" do
      s = slave(:s_axis, iface)
      mo = master(:m_axis, iface)
      realign = input(:realign, 1)
      aligned_o = output(:aligned, 1)

      aligned = reg(:aligned_r, 1)
      pkt = reg(:pkt, 3)
      first = reg(:first, 1, reset: 1)
      drop = reg(:drop, 1)
      lfsr = reg(:lfsr, 15, reset: @seed)
      out_v = reg(:out_v, 1)
      out_d = reg(:out_d, 8, reset: nil)
      out_l = reg(:out_l, 1, reset: nil)
      out_u = if user > 0, do: reg(:out_u, user, reset: nil)

      ce = wire(:ce, not out_v or mo.tready)
      acc = wire(:acc, s.tvalid and ce)
      start_new = wire(:start_new, first and not aligned and s.tdata == 0xB8)
      al = wire(:al, aligned or start_new)
      pk = wire(:pk, mux(start_new, 0, pkt))
      dropping = wire(:dropping, mux(first, not al, drop))
      group_start = wire(:group_start, first and pk == 0)
      {ns, prbs} = Scrambler.network(lfsr, s.tdata, m)
      ns = wire(:ns, ns)
      prbs = wire(:prbs, prbs)

      s.tready <~ ce
      mo.tvalid <~ out_v
      mo.tdata <~ out_d
      mo.tlast <~ out_l
      if user > 0, do: mo.tuser <~ out_u
      aligned_o <~ aligned

      sync do
        if ce, do: out_v <~ (acc and not dropping)

        if acc do
          out_d <~ mux(first, 0x47, prbs)
          out_l <~ s.tlast
          if user > 0, do: out_u <~ s.tuser
          aligned <~ al
          first <~ s.tlast
          drop <~ dropping

          if al do
            lfsr <~ mux(group_start, @seed, ns)
          end

          pkt <~ mux(s.tlast and al, mux(pk == 7, 0, trunc(pk + 1, 3)), pk)
        end

        if realign do
          aligned <~ 0
          pkt <~ 0
        end
      end
    end
  end
end
