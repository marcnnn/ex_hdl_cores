defmodule ExHdlCores.DVBT.OuterDecoderTest do
  use ExUnit.Case, async: true

  alias ExHdlCores.{ByteStream, DVBT.OuterDecoder}
  alias ExSdr.Comm.Bits
  alias ExSdr.Comm.Convolutional, as: CC
  alias ExSdr.DVBT.Convolutional, as: DC
  alias ExSdr.DVBT.{EnergyDispersal, OuterInterleaver, Receiver, ReedSolomon}

  # A transport stream of `packets` packets through the transmitter's outer chain and the
  # rate 1/2 convolutional code; bursts of code bit errors `{start, length}` are flipped.
  # Returns the code bits and the Viterbi output bytes of ex_sdr's decoder.
  defp channel(packets, seed, bursts) do
    :rand.seed(:exsss, {seed, 4, 5})
    ts = for _ <- 1..packets, into: <<>>, do: <<0x47, :rand.bytes(187)::binary>>

    tx =
      ts
      |> EnergyDispersal.scramble()
      |> then(&for(<<p::binary-size(188) <- &1>>, into: <<>>, do: ReedSolomon.encode(p)))
      |> OuterInterleaver.interleave()

    bits = DC.encode(for(<<b::1 <- tx>>, do: b), {1, 2})

    flips =
      for {start, len} <- bursts, i <- start..(start + len - 1), into: MapSet.new(), do: i

    code_bits =
      bits
      |> Enum.with_index()
      |> Enum.map(fn {b, i} -> if i in flips, do: 1 - b, else: b end)
      |> :binary.list_to_bin()

    dec = CC.decoder(DC.code({1, 2}), start: :unknown, depth: 128)
    {d1, dec} = CC.decode_stream(dec, code_bits)
    {d2, _} = CC.flush(dec)
    %{ts: ts, code_bits: code_bits, viterbi: Bits.pack(d1 <> d2)}
  end

  # the receiver's own back end (deinterleaver, Reed-Solomon, descrambler) on the same code bits
  defp receiver(code_bits) do
    st =
      Receiver.Stream.new(
        constellation: :qpsk,
        code_rate: {1, 2},
        front_end: :float,
        prepare: false,
        freq_offset: 0
      )

    {a, st} = Receiver.Stream.push_back(st, code_bits)
    {b, st} = Receiver.Stream.flush_back(st)
    {a <> b, st.rs_corrected, st.rs_failed}
  end

  defp hardware(bytes, opts) do
    r =
      ByteStream.run(
        OuterDecoder.build(),
        ByteStream.beats([bytes], last: false),
        [
          fields: [:tdata],
          out_fields: [:tdata, :tlast, :tuser],
          watch: [:stat_valid, :stat_failed, :stat_errors],
          idle: 700
        ] ++ opts
      )

    {r.out.m_axis |> Enum.map(& &1.tdata) |> :binary.list_to_bin(), r}
  end

  test "clean stream: the transport stream comes out, delayed by 11 packets" do
    c = channel(40, 1, [])
    {expected, 0, 0} = receiver(c.code_bits)
    assert expected == binary_part(c.ts, 0, byte_size(expected))
    assert byte_size(expected) == 29 * 188

    {out, r} = hardware(c.viterbi, valid: 100, ready: 100)
    assert out == expected
    assert r.watched.stat_valid == 29
    assert r.watched.stat_failed == 0
    assert r.watched.stat_errors == 0

    # packets of 188 bytes with tlast, flags clear
    assert Enum.map(ByteStream.packets(r.out.m_axis), &byte_size(elem(&1, 0))) ==
             List.duplicate(188, 29)

    assert Enum.all?(r.out.m_axis, &(&1.tuser == 0))
  end

  test "errors after the Viterbi decoder: corrected and failed packets, as the receiver" do
    # a few short bursts (corrected by the code or the Viterbi decoder) and heavy ones
    # that break several Reed-Solomon codewords
    bursts = [
      {500, 12},
      {9000, 30},
      {20_000, 150},
      {52_000, 400},
      {80_000, 9},
      {100_000, 600},
      {60_000, 4000}
    ]

    c = channel(40, 2, bursts)
    {expected, corrected, failed} = receiver(c.code_bits)
    assert corrected > 0 and failed > 0, "the test needs both: #{corrected} #{failed}"

    {out, r} = hardware(c.viterbi, valid: 90, ready: 70, seed: 3)
    assert byte_size(out) == byte_size(expected)
    assert out == expected
    assert r.watched.stat_errors == corrected
    assert r.watched.stat_failed == failed
    assert r.watched.stat_valid == 29

    flags = r.out.m_axis |> ByteStream.packets() |> Enum.map(fn {_, last} -> last.tuser end)
    assert Enum.count(flags, &(Bitwise.band(&1, 1) == 1)) == failed
  end

  @tag :verilator
  test "Verilator equals the BEAM simulator on the whole chain" do
    c = channel(16, 5, [{3000, 80}, {40_000, 1500}])
    bytes = c.viterbi

    opts = [
      valid: 85,
      ready: 75,
      seed: 7,
      fields: [:tdata],
      out_fields: [:tdata, :tlast, :tuser],
      idle: 500
    ]

    mod = OuterDecoder.build()
    beats = ByteStream.beats([bytes], last: false)
    a = ByteStream.run(mod, beats, opts)
    b = ByteStream.run(mod, beats, opts ++ [backend: :verilator])
    assert a.out == b.out
    assert a.cycles == b.cycles
    {expected, _, _} = receiver(c.code_bits)
    assert a.out.m_axis |> Enum.map(& &1.tdata) |> :binary.list_to_bin() == expected
  end
end
