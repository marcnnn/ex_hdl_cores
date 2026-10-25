defmodule ExHdlCores.ViterbiTb do
  @moduledoc false
  # Test bench for ExHdlCores.Viterbi: streams of code bits through the
  # module (BEAM simulator or Verilator) with random valid/ready, and the
  # ex_sdr streaming decoder as the reference.
  alias ExHdl.RTL.{Cosim.Session, Sim}
  alias ExHdlCores.{AxisDriver, Viterbi}
  alias ExSdr.Comm.Convolutional, as: CC
  alias ExSdr.DVBT.Convolutional, as: DV

  @doc "The ex_sdr code of a pattern (rows) with K, generators of `opts`."
  def code(rows, opts \\ []) do
    CC.new(
      constraint_length: Keyword.get(opts, :k, 7),
      polynomials: Keyword.get(opts, :polys, [0o171, 0o133]),
      puncture: rows
    )
  end

  @doc "ex_sdr's streaming decoder over `bits` (list of 0/1), flushed; decoded bits."
  def ex_sdr(code, bits, opts) do
    dec = CC.decoder(code, opts)
    {a, dec} = CC.decode_stream(dec, :binary.list_to_bin(bits))
    {b, _} = CC.flush(dec)
    :binary.bin_to_list(a <> b)
  end

  @doc "Random information bits."
  def info(n), do: for(_ <- 1..n, do: :rand.uniform(2) - 1)

  @doc "Encodes information bits at a DVB-T rate."
  def encode(bits, rate), do: DV.encode(bits, rate)

  @doc "Flips each bit with probability `p` per mille."
  def noise(bits, p), do: Enum.map(bits, &if(:rand.uniform(1000) <= p, do: 1 - &1, else: &1))

  @doc """
  Runs `streams` (`[%{bits: code bits, rate: pattern index}]`, one `tlast`
  each) back to back through `mod`; returns `{decoded streams, result}` where each
  decoded stream is `{bits, tlast beats}`.
  """
  def run(mod, streams, opts \\ []) do
    multi = Enum.any?(mod.ports, &(&1.name == :s_axis_tuser))

    beats =
      Enum.flat_map(streams, fn %{bits: bits} = s ->
        n = length(bits)

        bits
        |> Enum.with_index(1)
        |> Enum.map(fn {b, i} ->
          %{tdata: b, tlast: if(i == n, do: 1, else: 0), tuser: Map.get(s, :rate, 0)}
        end)
      end)

    sim =
      case Keyword.get(opts, :backend, :beam) do
        :beam -> mod |> Sim.new() |> Sim.reset(2)
        :verilator -> mod |> Session.open!() |> Session.reset(2)
      end

    fields = if multi, do: [:tdata, :tlast, :tuser], else: [:tdata, :tlast]

    try do
      r =
        AxisDriver.drive(
          sim,
          [
            inputs: %{s_axis: beats},
            outputs: [:m_axis],
            fields: fields,
            out_fields: [:tdata, :tlast],
            idle: 5000,
            max_cycles: Keyword.get(opts, :max_cycles, 2_000_000)
          ] ++ Keyword.take(opts, [:valid, :ready, :seed, :expect])
        )

      {split(r.out.m_axis), r}
    after
      if match?(%Session{}, sim), do: Session.close(sim)
    end
  end

  # beats -> list of decoded streams
  defp split(beats) do
    {streams, cur} =
      Enum.reduce(beats, {[], []}, fn b, {done, cur} ->
        if b.tdata > 1, do: raise("decoded bit is not 0/1: #{inspect(b)}")
        cur = [b.tdata | cur]
        if b.tlast == 1, do: {[Enum.reverse(cur) | done], []}, else: {done, cur}
      end)

    if cur != [], do: raise("output ends without tlast: #{length(cur)} bits")
    Enum.reverse(streams)
  end

  @doc "Decoded stream of the reference model for a DVB-T rate index."
  def expected(bits, rate_index, depth, opts \\ []) do
    rate = Enum.at(Viterbi.dvbt_rates(), rate_index)
    ex_sdr(DV.code(rate), bits, [depth: depth] ++ opts)
  end
end
