defmodule ExHdlCores.Tb do
  @moduledoc false
  # Test bench helpers: random stimulus for co-simulation, AXI4-Stream
  # beats and packets, and a stream driver with random valid/ready.
  import Bitwise
  alias ExHdl.RTL.Module

  @doc "Random input events for `Cosim.assert_equivalent/3`; resets low for the first `reset` events."
  def random_stimulus(mod, n, seed, opts \\ []) do
    :rand.seed(:exsss, {seed, 11, 12})
    reset = Keyword.get(opts, :reset, 4)
    bias = Keyword.get(opts, :bias, %{})

    for i <- 0..(n - 1) do
      resets =
        for p <- mod.ports,
            p.role == :reset,
            into: %{},
            do: {p.name, if(i < reset, do: 0, else: 1)}

      mod
      |> Module.data_inputs()
      |> Map.new(fn p ->
        {w, pct} = {elem(p.type, 1), Map.get(bias, p.name)}

        v =
          cond do
            pct == nil -> :rand.uniform(1 <<< w) - 1
            :rand.uniform(100) <= pct -> (1 <<< w) - 1
            true -> 0
          end

        {p.name, v}
      end)
      |> Map.merge(resets)
    end
  end

  # -- packets and beats (moved to ExHdlCores.AxisDriver) --------------------------------

  defdelegate beats(packet, bytes, extra \\ %{}), to: ExHdlCores.AxisDriver
  defdelegate packets(beats, bytes), to: ExHdlCores.AxisDriver
  defdelegate drive(sim, opts), to: ExHdlCores.AxisDriver
end
