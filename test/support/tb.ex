defmodule ExHdlCores.Tb do
  @moduledoc false
  # Test bench helpers: random stimulus for co-simulation, AXI4-Stream
  # beats and packets, and a stream driver with random valid/ready.
  import Bitwise
  alias ExHdl.RTL.{Module, Sim}

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

  # -- packets and beats -----------------------------------------------------------------

  @doc "Beats (`%{tdata, tkeep, tlast}`) of a packet on a bus of `bytes` bytes, byte 0 in the low bits."
  def beats(packet, bytes, extra \\ %{}) do
    chunks = for <<c::binary-size(bytes) <- packet>>, do: c
    rest = binary_part(packet, length(chunks) * bytes, rem(byte_size(packet), bytes))
    chunks = if rest == "", do: chunks, else: chunks ++ [rest]
    n = length(chunks)

    chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {c, i} ->
      k = byte_size(c)

      Map.merge(extra, %{
        tdata: :binary.decode_unsigned(c, :little),
        tkeep: (1 <<< k) - 1,
        tlast: if(i == n, do: 1, else: 0)
      })
    end)
  end

  @doc "Packets (binaries) from beats; beats without tlast at the end are ignored."
  def packets(beats, bytes) do
    {pkts, _} =
      Enum.reduce(beats, {[], []}, fn b, {pkts, cur} ->
        k = b.tkeep |> Integer.digits(2) |> Enum.sum()
        bin = <<b.tdata::little-size(8 * bytes)>> |> binary_part(0, k)
        cur = [bin | cur]

        if b.tlast == 1,
          do: {[cur |> Enum.reverse() |> IO.iodata_to_binary() | pkts], []},
          else: {pkts, cur}
      end)

    Enum.reverse(pkts)
  end

  # -- stream driver ---------------------------------------------------------------------

  @doc """
  Drives `sim` for AXI4-Stream ports. Options:

    * `inputs:` `%{prefix => beats}` - slave ports of the DUT (`prefix_tdata`, ...)
    * `outputs:` list of master port prefixes
    * `valid:`/`ready:` - percent of cycles offering / accepting (default 70)
    * `seed:`, `max_cycles:`, `idle:` (cycles without activity after the
      last expected output before stopping, default 30)
    * `expect:` number of output beats in total to wait for (default: until idle)
    * `pre:` `fn sim, cycle -> sim end` for other inputs
    * `clocks:` `%{prefix => clock_port}` for multi-clock DUTs: a port only
      transfers at events where its clock rises
    * `watch:` output names summed over all cycles (pulse counters)

  Checks the AXI4-Stream rules on every port (tvalid held and payload
  stable until accepted). Returns `%{out: %{prefix => beats}, cycles: n,
  consumed: %{prefix => n}}`.
  """
  def drive(sim, opts) do
    :rand.seed(:exsss, {Keyword.get(opts, :seed, 1), 21, 22})
    inputs = Keyword.fetch!(opts, :inputs)
    outputs = Keyword.fetch!(opts, :outputs)
    vp = Keyword.get(opts, :valid, 70)
    rp = Keyword.get(opts, :ready, 70)
    max = Keyword.get(opts, :max_cycles, 20_000)
    idle = Keyword.get(opts, :idle, 30)
    expect = Keyword.get(opts, :expect)
    pre = Keyword.get(opts, :pre, fn sim, _ -> sim end)
    fields = Keyword.get(opts, :fields, [:tdata, :tkeep, :tlast])
    clocks = Keyword.get(opts, :clocks)
    watch = Keyword.get(opts, :watch, [])

    state = %{
      todo: inputs,
      held: Map.new(inputs, fn {p, _} -> {p, nil} end),
      out: Map.new(outputs, &{&1, []}),
      stall: Map.new(outputs, &{&1, nil}),
      quiet: 0,
      total: 0,
      watched: Map.new(watch, &{&1, 0})
    }

    result =
      Enum.reduce_while(1..max, {sim, state}, fn cycle, {sim, st} ->
        sim = pre.(sim, cycle)

        # offers: a presented beat stays presented until accepted
        {pokes, held} =
          Enum.reduce(st.todo, {%{}, st.held}, fn {p, beats}, {pk, held} ->
            offer =
              cond do
                beats == [] -> false
                held[p] != nil -> true
                true -> :rand.uniform(100) <= vp
              end

            held = Map.put(held, p, if(offer, do: true))
            {Map.merge(pk, beat_pokes(p, if(offer, do: hd(beats)), fields)), held}
          end)

        readies = Map.new(outputs, &{&1, :rand.uniform(100) <= rp})

        pokes =
          Enum.reduce(readies, pokes, fn {p, r}, pk ->
            Map.put(pk, :"#{p}_tready", if(r, do: 1, else: 0))
          end)

        sim = Sim.poke(sim, pokes)
        outs = Sim.outputs(sim)
        edges = if clocks, do: Sim.next_edges(sim), else: []
        fires = fn p -> clocks == nil or clocks[p] in edges end

        # input transfers
        {todo, held, in_xfer} =
          Enum.reduce(st.todo, {%{}, held, 0}, fn {p, beats}, {todo, held, n} ->
            if held[p] && outs[:"#{p}_tready"] == 1 && fires.(p),
              do: {Map.put(todo, p, tl(beats)), Map.put(held, p, nil), n + 1},
              else: {Map.put(todo, p, beats), held, n}
          end)

        # output transfers and protocol checks
        {out, stall, out_xfer} =
          Enum.reduce(outputs, {st.out, st.stall, 0}, fn p, {out, stall, n} ->
            valid = outs[:"#{p}_tvalid"] == 1
            beat = Map.new(fields, &{&1, Map.get(outs, :"#{p}_#{&1}")})

            if stall[p] != nil and not (valid and beat == stall[p]),
              do:
                raise(
                  "#{p}: output changed or tvalid dropped while stalled: #{inspect({stall[p], valid, beat})}"
                )

            cond do
              valid and readies[p] and fires.(p) ->
                {Map.update!(out, p, &[beat | &1]), Map.put(stall, p, nil), n + 1}

              valid ->
                {out, Map.put(stall, p, beat), n}

              true ->
                {out, stall, n}
            end
          end)

        total = st.total + out_xfer
        waiting = Enum.any?(outputs, &(outs[:"#{&1}_tvalid"] == 1))
        busy = in_xfer + out_xfer > 0 or waiting or Enum.any?(todo, fn {_, b} -> b != [] end)
        quiet = if busy, do: 0, else: st.quiet + 1

        watched = Map.new(st.watched, fn {k, v} -> {k, v + outs[k]} end)

        st = %{
          st
          | todo: todo,
            held: held,
            out: out,
            stall: stall,
            quiet: quiet,
            total: total,
            watched: watched
        }

        sim = Sim.step(sim)

        done = quiet >= idle or (expect != nil and total >= expect and quiet >= 3)

        if done do
          consumed = Map.new(inputs, fn {p, b} -> {p, length(b) - length(todo[p])} end)

          {:halt,
           %{
             out: Map.new(out, fn {p, l} -> {p, Enum.reverse(l)} end),
             cycles: cycle,
             consumed: consumed,
             watched: st.watched,
             sim: sim
           }}
        else
          {:cont, {sim, st}}
        end
      end)

    case result do
      %{} = r ->
        r

      {sim, st} ->
        if Keyword.get(opts, :timeout_ok, false) do
          consumed = Map.new(inputs, fn {p, b} -> {p, length(b) - length(st.todo[p])} end)

          %{
            out: Map.new(st.out, fn {p, l} -> {p, Enum.reverse(l)} end),
            cycles: max,
            consumed: consumed,
            watched: st.watched,
            sim: sim
          }
        else
          raise "stream driver: max_cycles reached"
        end
    end
  end

  defp beat_pokes(p, nil, fields),
    do: Map.new([{:"#{p}_tvalid", 0} | Enum.map(fields, &{:"#{p}_#{&1}", 0})])

  defp beat_pokes(p, beat, fields),
    do: Map.new([{:"#{p}_tvalid", 1} | Enum.map(fields, &{:"#{p}_#{&1}", Map.get(beat, &1, 0)})])
end
