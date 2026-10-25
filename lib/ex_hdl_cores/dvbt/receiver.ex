defmodule ExHdlCores.DVBT.Receiver do
  @moduledoc """
  DVB-T receiver in hardware, 2k mode: `sc16` samples in, MPEG transport
  stream packets out, the same bytes as `ExSdr.DVBT.Receiver.Stream` with
  `front_end: :fixed`, `input: :sc16` and a given `freq_offset` (the first
  sample starts a superframe; acquisition stays in software).

      sc16 -> ExHdl.OFDM.FrontEnd (correction, guard removal, FFT, equaliser,
              deinterleavers, code bits) -> FIFO -> Viterbi -> bit packer
              -> OuterDecoder (Forney deinterleaver, RS(204, 188), descrambler)

  ## Ports

    * `s_axis`: `tdata = {im[15:0], re[15:0]}`, signed Q15, full scale 1.0;
      the front end takes one sample per clock when it can, and the
      source (a radio) cannot wait: a sample offered while `s_axis_tready`
      is low is lost and counted in `overflow`. `tlast` is not used.
    * `inc`, `phase0`, `load`: the frequency correction, see
      `phase_words/2`; set before the first sample, `load` for one cycle.
    * `m_axis`: transport stream bytes, 188 per packet with `tlast`, `tuser`
      = `{corrected, failed}` (bit 0 failed) of the packet's Reed-Solomon
      codeword on every beat.
    * counters (32 bit, from reset): `packets` (codewords decoded),
      `rs_failed`, `rs_errors` (symbol errors corrected, ex_sdr's
      `rs_corrected`), `overflow` (input beats lost), `blocks`
      (bit-interleaver blocks of 126 constellation words that reached the
      FIFO). `aligned` (descrambler found its first sync byte) and `realign`
      (a pulse: look for the next one) as in `ExHdlCores.DVBT.OuterDecoder`.
      `fifo_level` and `fifo_peak` are the bits in the FIFO in front of the
      Viterbi decoder and its maximum. `viterbi_last` is the decoder's
      `tlast`, which never rises (the stream has no end).

  ## Differences from ex_sdr

  The Viterbi decoder runs the sliding window traceback and is not flushed:
  ex_sdr's `Receiver.Stream.flush/1` decodes the last window, the hardware
  keeps it (about 128 steps, 16 bytes) until more code bits arrive. The
  front end takes any number of samples; ex_sdr works in chunks of whole
  groups of 4 symbols, so compare after a multiple of 4 symbols. Only the
  guard interval 1/32 of `ExSdr.DVBT.OFDM.ofdm/0` is generated. The
  options are `:constellation` (`:qpsk`, `:qam16`, `:qam64`), `:code_rate`
  (`{1, 2}`, `{2, 3}`, `{3, 4}`, `{5, 6}`, `{7, 8}`), `:guard` (`{1, 32}`),
  `:fifo_depth` (bits, a power of two, default
  16384: one RAMB18), `:slots` (RS codeword buffers, 4), `:spec` (the
  front end spec, default `ExSdr.DVBT.Receiver.front_end_spec/1`), `:name`.
  """
  use ExHdl.RTL
  alias ExHdl.OFDM.{Correct, FrontEnd}
  alias ExHdlCores.{AXIS, FIFO, Viterbi}
  alias ExHdlCores.DVBT.{BitPacker, OuterDecoder}

  @doc """
  The correction words for a frequency offset (subcarrier spacings, as
  `Receiver.Stream`'s `:freq_offset`): `{inc, phase0}` for the `inc` and
  `phase0` ports, for a first sample that is sample `start` of the
  correction's phase (default 0).
  """
  def phase_words(freq_offset, start \\ 0) do
    inc = apply(fixed_front_end(), :phase_increment, [freq_offset, 2048])
    {inc, Correct.phase0(inc, start)}
  end

  defp fixed_front_end, do: Module.concat([ExSdr, Comm, OFDM, FixedFrontEnd])

  defp default_spec(constellation) do
    mod = Module.concat([ExSdr, DVBT, Receiver])

    unless Code.ensure_loaded?(mod),
      do: raise(ArgumentError, "dvbt receiver: pass :spec, ex_sdr is not available")

    apply(mod, :front_end_spec, [constellation])
  end

  @doc "Elaborated receiver, `{:ok, %{module:, front_end:, ...}}`; options in the moduledoc."
  def build(opts) do
    constellation = Keyword.fetch!(opts, :constellation)
    rate = Keyword.fetch!(opts, :code_rate)
    name = Keyword.get(opts, :name, "dvbt_receiver")
    depth = Keyword.get(opts, :fifo_depth, 16_384)

    unless constellation in [:qpsk, :qam16, :qam64] and rate in Viterbi.dvbt_rates() and
             Keyword.get(opts, :guard, {1, 32}) == {1, 32} do
      raise ArgumentError,
            "dvbt receiver: constellation :qpsk | :qam16 | :qam64, a DVB-T code rate, guard {1, 32}"
    end

    spec = Keyword.get_lazy(opts, :spec, fn -> default_spec(constellation) end)

    with {:ok, fe} <-
           FrontEnd.build(spec, name: name <> "_fe", fft: :hardware) do
      vit =
        Viterbi.build(
          puncture: [Viterbi.dvbt_pattern(rate)],
          width: 1,
          start: :unknown,
          name: name <> "_viterbi"
        )

      fifo = FIFO.axis(data: 1, keep: false, last: false, depth: depth, count: true)
      packer = BitPacker.build()
      outer = OuterDecoder.build(slots: Keyword.get(opts, :slots, 4))

      parts = %{fe: fe.module, fifo: fifo, vit: vit, packer: packer, outer: outer, depth: depth}
      {:ok, %{module: top(name, parts), front_end: fe, viterbi: vit, fifo: fifo}}
    end
  end

  defp top(name, p) do
    cw = ExHdl.RTL.Builder.ceil_log2(p.depth) + 1

    module name do
      s = slave(:s_axis, AXIS.iface(data: 32, keep: false, last: false))
      mo = master(:m_axis, AXIS.iface(data: 8, keep: false, user: 2))
      inc = input(:inc, 32, domain: :static)
      phase0 = input(:phase0, 32, domain: :static)
      load = input(:load, 1)
      realign = input(:realign, 1)
      aligned = output(:aligned, 1)
      fifo_level = output(:fifo_level, cw)
      fifo_peak = output(:fifo_peak, cw)
      viterbi_last = output(:viterbi_last, 1)
      packets = output(:packets, 32)
      rs_failed = output(:rs_failed, 32)
      rs_errors = output(:rs_errors, 32)
      overflow = output(:overflow, 32)
      blocks = output(:blocks, 32)

      fe = instance(:fe, p.fe)
      fifo = instance(:fifo, p.fifo)
      vit = instance(:vit, p.vit)
      pk = instance(:packer, p.packer)
      od = instance(:outer, p.outer)

      fe.inc <~ inc
      fe.phase0 <~ phase0
      fe.load <~ load
      fe.s_axis.tdata <~ s.tdata
      fe.s_axis.tvalid <~ s.tvalid
      fe.s_axis.tlast <~ 0
      s.tready <~ fe.s_axis.tready

      fifo.s_axis_tdata <~ fe.m_axis.tdata
      fifo.s_axis_tvalid <~ fe.m_axis.tvalid
      fe.m_axis.tready <~ fifo.s_axis_tready

      vit.s_axis_tdata <~ fifo.m_axis_tdata
      vit.s_axis_tvalid <~ fifo.m_axis_tvalid
      vit.s_axis_tlast <~ 0
      fifo.m_axis_tready <~ vit.s_axis_tready

      pk.s_axis.tdata <~ vit.m_axis_tdata
      pk.s_axis.tvalid <~ vit.m_axis_tvalid
      vit.m_axis_tready <~ pk.s_axis.tready

      od.s_axis.tdata <~ pk.m_axis.tdata
      od.s_axis.tvalid <~ pk.m_axis.tvalid
      pk.m_axis.tready <~ od.s_axis.tready

      connect(od.m_axis, mo)
      od.realign <~ realign

      aligned <~ od.aligned
      viterbi_last <~ vit.m_axis_tlast
      fifo_level <~ fifo.count

      packets_r = reg(:packets_r, 32)
      failed_r = reg(:failed_r, 32)
      errors_r = reg(:errors_r, 32)
      overflow_r = reg(:overflow_r, 32)
      blocks_r = reg(:blocks_r, 32)
      peak_r = reg(:peak_r, cw)

      sync do
        if od.stat_valid, do: packets_r <~ add_wrap(packets_r, 1)
        if od.stat_failed, do: failed_r <~ add_wrap(failed_r, 1)
        errors_r <~ add_wrap(errors_r, zext(od.stat_errors, 32))
        if s.tvalid and not fe.s_axis.tready, do: overflow_r <~ add_wrap(overflow_r, 1)

        if fe.m_axis.tvalid and fe.m_axis.tlast and fifo.s_axis_tready,
          do: blocks_r <~ add_wrap(blocks_r, 1)

        if fifo.count > peak_r, do: peak_r <~ fifo.count
      end

      packets <~ packets_r
      rs_failed <~ failed_r
      rs_errors <~ errors_r
      overflow <~ overflow_r
      blocks <~ blocks_r
      fifo_peak <~ peak_r
    end
  end
end
