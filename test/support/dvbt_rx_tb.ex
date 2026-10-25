defmodule ExHdlCores.DVBTRxTb do
  @moduledoc false
  # Test bench for ExHdlCores.DVBT.Receiver: the DVB-T test signal, the
  # reference (ExSdr.DVBT.Receiver.Stream, fixed-point front end on sc16, no
  # acquisition) and a closed-loop Verilator run that records when samples
  # go in and bytes come out.
  import Bitwise
  alias ExHdl.RTL.Cosim.Session
  alias ExSdr.Comm.OFDM.FixedFrontEnd
  alias ExSdr.DVBT.{Channel, OFDM, Receiver, TestSignal, Transmitter}

  @sym 2112

  @doc """
  `symbols` OFDM symbols of ExSdr's transmitter on the test transport
  stream (2k, guard 1/32) with a carrier offset and noise:
  `{sc16 samples (s16 tensor), freq_offset for the receiver}`.
  """
  def signal(constellation, rate, symbols, opts \\ []) do
    o = [constellation: constellation, code_rate: rate, guard_interval: {1, 32}, cell_id: 0]
    ts = TestSignal.ts_packets(packets(constellation, rate))
    cfo = Keyword.get(opts, :cfo, 0.37)

    x =
      ts
      |> Transmitter.symbols(o)
      |> Enum.take(symbols)
      |> OFDM.modulate(o)
      |> Channel.frequency_offset(cfo)
      |> Channel.awgn(Keyword.get(opts, :snr, 12.0), 42)

    {FixedFrontEnd.to_sc16(x, 0.47), cfo}
  end

  # the smallest whole number of groups of 8 packets (at least 160) whose code bits fill whole
  # 126-word blocks of the bit interleaver, as the transmitter needs
  defp packets(constellation, {num, den}) do
    v = %{qpsk: 2, qam16: 4, qam64: 6}[constellation]

    Enum.find(160..100_000//8, fn p ->
      info = p * 204 * 8
      rem(info * den, num) == 0 and rem(div(info * den, num), 126 * v) == 0
    end)
  end

  @doc "Transport stream bytes, RS corrected (symbol errors) and failed of the software receiver; no flush."
  def reference(sc16, constellation, rate, freq_offset) do
    st =
      Receiver.Stream.new(
        constellation: constellation,
        code_rate: rate,
        front_end: :fixed,
        fixed_opts: [compiler: Nx.Defn.Evaluator],
        input: :sc16,
        freq_offset: freq_offset,
        chunk_symbols: 4
      )

    {ts, st} = Receiver.Stream.push(st, sc16)
    {ts, st.rs_corrected, st.rs_failed}
  end

  defp word(re, im), do: (im &&& 0xFFFF) <<< 16 ||| (re &&& 0xFFFF)

  @doc """
  Runs the receiver module on `sc16` in Verilator until `expect` bytes came
  out (then a few hundred idle cycles to see that nothing else does).

  Options: `period:` clocks per sample (default 10; 1 = as fast as the
  design takes them), `ready:` percent of cycles the sink accepts, `seed:`,
  `max_cycles:`, `expect:` bytes. Returns `%{bytes:, flags:` (tuser of the
  last beat of each packet)`, out_cycles:` (cycle of every output byte),
  `symbol_end:` (cycle in which the last sample of each symbol was taken),
  `first_in:`, `cycles:, final:` (outputs of the design at the end), `peak:`
  `}`.
  """
  def run(mod, sc16, freq_offset, opts) do
    period = Keyword.get(opts, :period, 10)
    rp = Keyword.get(opts, :ready, 70)
    max = Keyword.get(opts, :max_cycles, 5_000_000)
    expect = Keyword.fetch!(opts, :expect)
    :rand.seed(:exsss, {Keyword.get(opts, :seed, 1), 3, 4})

    samples =
      sc16 |> Nx.reshape({:auto, 2}) |> Nx.to_list() |> Enum.map(fn [re, im] -> word(re, im) end)

    {inc, phase0} = ExHdlCores.DVBT.Receiver.phase_words(freq_offset)
    sim = mod |> Session.open!() |> Session.reset(2)

    try do
      init = %{
        todo: samples,
        held: false,
        taken: 0,
        bytes: [],
        out_cycles: [],
        ends: [],
        first_in: nil,
        idle: 0,
        flags: [],
        outs: nil
      }

      st =
        Enum.reduce_while(1..max, init, fn cycle, st ->
          offer = st.todo != [] and cycle > 8 and (st.held or rem(cycle, period) == 0)
          ready = :rand.uniform(100) <= rp

          Session.poke(sim,
            inc: inc,
            phase0: phase0,
            load: if(cycle == 4, do: 1, else: 0),
            s_axis_tvalid: if(offer, do: 1, else: 0),
            s_axis_tdata: if(offer, do: hd(st.todo), else: 0),
            m_axis_tready: if(ready, do: 1, else: 0),
            realign: 0
          )

          o = Session.outputs(sim)

          st =
            if offer and o.s_axis_tready == 1 do
              k = st.taken + 1

              %{
                st
                | todo: tl(st.todo),
                  taken: k,
                  first_in: st.first_in || cycle,
                  ends: if(rem(k, @sym) == 0, do: [cycle | st.ends], else: st.ends)
              }
              |> Map.put(:held, false)
            else
              %{st | held: offer}
            end

          st =
            if o.m_axis_tvalid == 1 and ready do
              %{
                st
                | bytes: [o.m_axis_tdata | st.bytes],
                  out_cycles: [cycle | st.out_cycles],
                  flags: if(o.m_axis_tlast == 1, do: [o.m_axis_tuser | st.flags], else: st.flags)
              }
            else
              st
            end

          st = %{st | outs: o}
          Session.step(sim)
          got = length(st.bytes)
          st = if got >= expect, do: %{st | idle: st.idle + 1}, else: st

          if st.idle > 800, do: {:halt, Map.put(st, :cycles, cycle)}, else: {:cont, st}
        end)

      st = Map.put_new(st, :cycles, max)

      %{
        bytes: st.bytes |> Enum.reverse() |> :binary.list_to_bin(),
        flags: Enum.reverse(st.flags),
        out_cycles: Enum.reverse(st.out_cycles),
        symbol_end: Enum.reverse(st.ends),
        first_in: st.first_in,
        cycles: st.cycles,
        final: st.outs
      }
    after
      Session.close(sim)
    end
  end
end
