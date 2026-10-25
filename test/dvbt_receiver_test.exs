defmodule ExHdlCores.DVBT.ReceiverTest do
  @moduledoc """
  The hardware DVB-T receiver end to end in Verilator against
  `ExSdr.DVBT.Receiver.Stream` (fixed-point front end on sc16, known
  synchronisation) on ExSdr's transmitter signal with a carrier offset and
  noise: same transport stream bytes, same Reed-Solomon counts, random
  backpressure on the output.
  """
  use ExUnit.Case, async: true

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdlCores.{DVBT.Receiver, DVBTRxTb, Viterbi}

  @moduletag :verilator
  @moduletag timeout: 1_800_000
  @sym 2112

  defp check(c, rate, symbols, opts) do
    {sc16, cfo} = DVBTRxTb.signal(c, rate, symbols, snr: Keyword.fetch!(opts, :snr))
    {ts, corrected, failed} = DVBTRxTb.reference(sc16, c, rate, cfo)
    assert byte_size(ts) >= 8 * 188
    {:ok, d} = Receiver.build(constellation: c, code_rate: rate)
    r = DVBTRxTb.run(d.module, sc16, cfo, [expect: byte_size(ts)] ++ opts)

    assert byte_size(r.bytes) == byte_size(ts)
    assert r.bytes == ts
    # codewords before the descrambler's first sync byte are counted but not output
    assert r.final.packets >= div(byte_size(ts), 188)
    assert r.final.rs_errors == corrected
    assert r.final.rs_failed == failed
    assert r.final.viterbi_last == 0
    # the last symbols are still in the front end when the expected bytes are out
    assert r.final.blocks in (div(symbols * 1512, 126) - 12)..div(symbols * 1512, 126)
    # the flags of the output packets (failed codewords before the first group are not output)
    assert Enum.count(r.flags, &(Bitwise.band(&1, 1) == 1)) <= failed
    {r, d, corrected, failed}
  end

  # the first sample after which output packet `n` can be complete: the code bits the Viterbi
  # window needs for its last byte (after the deinterleaver delay of 2244 bytes)
  defp needed_samples(n, c, {_, _} = rate, depth \\ 128) do
    bits = 8 * (2244 + 204 * (n + 1))
    steps = (div(bits - 1, depth) + 2) * depth
    [x, y] = Viterbi.dvbt_pattern(rate)
    p = length(x)
    per = Enum.sum(x) + Enum.sum(y)
    tail = Enum.take(x, rem(steps, p)) ++ Enum.take(y, rem(steps, p))
    code_bits = div(steps, p) * per + Enum.sum(tail)
    v = %{qpsk: 2, qam16: 4, qam64: 6}[c]
    (div(code_bits - 1, 1512 * v) + 1) * @sym
  end

  test "QPSK 1/2 at 10 Msamples/s (100 MHz clock): same bytes, no overflow, latency" do
    {r, _, 0, 0} = check(:qpsk, {1, 2}, 28, snr: 12.0, period: 10, ready: 100)
    assert r.final.overflow == 0
    assert r.final.packets == 14
    # the 25 codewords of 28 symbols, 14 of them out
    assert byte_size(r.bytes) == 14 * 188

    # latency from the last sample of the symbol that completes packet n to its first byte
    lat =
      for n <- 0..13 do
        s = div(needed_samples(n, :qpsk, {1, 2}), @sym)
        Enum.at(r.out_cycles, n * 188) - Enum.at(r.symbol_end, s - 1)
      end

    # one symbol is 21120 clocks: the chain answers within half a symbol
    assert Enum.all?(lat, &(&1 in 1000..12_000)), inspect(lat)
    assert r.final.fifo_peak < 2000
  end

  test "QPSK 7/8 with errors, random backpressure" do
    {_, _, corrected, failed} = check(:qpsk, {7, 8}, 28, snr: 10.0, period: 3, ready: 60, seed: 5)
    assert corrected > 0 and failed > 0
  end

  test "16-QAM 2/3 with errors, random backpressure" do
    {_, _, corrected, failed} =
      check(:qam16, {2, 3}, 12, snr: 14.0, period: 2, ready: 70, seed: 6)

    assert corrected > 0 and failed > 0
  end

  test "64-QAM 3/4 with errors, random backpressure" do
    {_, _, corrected, failed} =
      check(:qam64, {3, 4}, 8, snr: 21.0, period: 3, ready: 80, seed: 7)

    assert corrected > 0 and failed > 0
  end

  test "64-QAM 7/8, the heaviest mode: sustained at the sample rate, and with the source as fast as the chain takes samples" do
    # 9.14 Msamples/s at 100 MHz is 10.94 clocks per sample; one sample per 10 clocks here
    {r, _, _, _} = check(:qam64, {7, 8}, 12, snr: 24.0, period: 10, ready: 100)
    assert r.final.overflow == 0
    assert r.final.fifo_peak < 8192

    {r, _, _, _} = check(:qam64, {7, 8}, 12, snr: 24.0, period: 1, ready: 100)
    ends = r.symbol_end
    # the slowest of the last symbols, after the FIFO has filled and the source is held back
    worst =
      ends
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)
      |> Enum.take(-3)
      |> Enum.max()

    assert worst / @sym < 10.94, "#{worst / @sym} clocks per sample"
  end

  test "the generated SystemVerilog lints clean under -Wall" do
    {:ok, d} = Receiver.build(constellation: :qpsk, code_rate: {1, 2})
    dir = Path.join(System.tmp_dir!(), "dvbt_rx_lint_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      files =
        for {name, src} <- SV.generate(d.module) do
          path = Path.join(dir, name)
          File.write!(path, src)
          path
        end

      {out, status} =
        System.cmd("verilator", ["--lint-only", "-Wall", "--top-module", d.module.name | files],
          stderr_to_stdout: true
        )

      assert status == 0, out
    after
      File.rm_rf!(dir)
    end
  end
end
