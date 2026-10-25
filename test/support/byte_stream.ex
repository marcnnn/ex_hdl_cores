defmodule ExHdlCores.ByteStream do
  @moduledoc false
  # Byte streams (AXI4-Stream with tdata 8, optional tlast and tuser, no
  # tkeep) through a module on the BEAM simulator or Verilator, with random
  # valid/ready from `ExHdlCores.AxisDriver.drive/2`.
  alias ExHdl.RTL.{Cosim.Session, Sim}
  alias ExHdlCores.AxisDriver

  @doc "Beats of a list of byte binaries; `tlast` on the last byte of each when `last: true`."
  def beats(packets, opts \\ []) do
    last = Keyword.get(opts, :last, true)
    extra = Keyword.get(opts, :extra, %{})

    Enum.flat_map(packets, fn p ->
      n = byte_size(p)

      for {b, i} <- Enum.with_index(:binary.bin_to_list(p), 1),
          do: Map.merge(extra, %{tdata: b, tlast: if(last and i == n, do: 1, else: 0)})
    end)
  end

  @doc """
  Runs `beats` into `s_axis` and collects `m_axis`. Options: `backend:`,
  `valid:`, `ready:`, `seed:`, `fields:` (input, default: the `s_axis` fields present), `out_fields:`, `pre:`,
  `watch:`, `max_cycles:`, `idle:`, `expect:`. Returns the `drive/2` map.
  """
  def run(mod, beats, opts \\ []) do
    sim =
      case Keyword.get(opts, :backend, :beam) do
        :beam -> mod |> Sim.new() |> Sim.reset(2)
        :verilator -> mod |> Session.open!() |> Session.reset(2)
      end

    try do
      drive_opts =
        opts
        |> Keyword.drop([:backend])
        |> Keyword.merge(inputs: %{s_axis: beats}, outputs: [:m_axis])
        |> Keyword.put_new(:fields, port_fields(mod, :s_axis))
        |> Keyword.put_new(:out_fields, port_fields(mod, :m_axis))

      AxisDriver.drive(sim, drive_opts)
    after
      if match?(%Session{}, sim), do: Session.close(sim)
    end
  end

  defp port_fields(mod, prefix) do
    names = Enum.map(mod.ports, & &1.name)
    for f <- [:tdata, :tlast, :tuser], :"#{prefix}_#{f}" in names, do: f
  end

  @doc "Output bytes of a run (`tdata` of the beats)."
  def bytes(r), do: Enum.map(r.out.m_axis, & &1.tdata)

  @doc "Splits output beats into packets by `tlast`: `[{binary, last_beat}]`."
  def packets(beats) do
    {pkts, _} =
      Enum.reduce(beats, {[], []}, fn b, {pkts, cur} ->
        cur = [b | cur]

        if b.tlast == 1,
          do:
            {[
               {cur |> Enum.reverse() |> Enum.map(& &1.tdata) |> :binary.list_to_bin(), hd(cur)}
               | pkts
             ], []},
          else: {pkts, cur}
      end)

    Enum.reverse(pkts)
  end
end
