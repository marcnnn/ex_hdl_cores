defmodule ExHdlCores.Util do
  @moduledoc """
  Small utilities. Every module has a BEAM model in `ExHdlCores.Util.Model`
  (one function per block, a list of per-cycle input maps in, a list of
  output maps out, sampled before each clock edge like `Sim.run/2`).

    * `counter/2` - counter with enable, clear and terminal count
    * `prescaler/2` - one `tick` every `div` enabled cycles
    * `timer/2` - loadable one-shot or periodic down-counter
    * `pulse_stretcher/2` - retriggerable pulse extender
    * `debouncer/2` - synchroniser plus stability filter, with edge pulses
    * `blinker/2` and `heartbeat/2` - LED drivers
  """
  use ExHdl.RTL
  alias ExHdl.RTL.{Builder, CDC}

  defp bits(n), do: max(Builder.ceil_log2(n), 1)

  @doc """
  Counter. Ports: `en`, `clear` (synchronous, wins over `en`), `count`
  (registered), `tc` (high while `count` equals `max`). Options: `max:`
  (default `2^width - 1`; the counter wraps to 0 after it), `down:`
  (false; counts down from `max` and wraps to `max`).
  """
  def counter(width, opts \\ []) do
    max = Keyword.get(opts, :max, Bitwise.bsl(1, width) - 1)
    down = Keyword.get(opts, :down, false)
    unless max in 1..(Bitwise.bsl(1, width) - 1), do: raise(ArgumentError, "max must fit width")

    module "counter_#{width}_#{max}#{if down, do: "_down", else: ""}" do
      en = input(:en, 1)
      clear = input(:clear, 1)
      count = output(:count, width, reset: if(down, do: max, else: 0))
      tc = output(:tc, 1)
      edge = if down, do: 0, else: max

      sync do
        if clear do
          count <~ if(down, do: max, else: 0)
        else
          if en do
            if count == edge do
              count <~ if(down, do: max, else: 0)
            else
              count <~ if(down, do: sub_wrap(count, 1), else: add_wrap(count, 1))
            end
          end
        end
      end

      tc <~ (count == edge)
    end
  end

  @doc """
  Prescaler. Ports: `en`, `tick` (combinational: high in the `div`-th
  enabled cycle, so `tick` is `en` when `div` is 1). The phase restarts
  with reset only.
  """
  def prescaler(div, _opts \\ []) when div >= 1 do
    module "prescaler_#{div}" do
      en = input(:en, 1)
      tick = output(:tick, 1)

      if div == 1 do
        tick <~ en
      else
        phase = reg(:phase, bits(div))
        last = wire(:last, phase == div - 1)

        sync do
          if en do
            if last, do: phase <~ 0, else: phase <~ add_wrap(phase, 1)
          end
        end

        tick <~ (en and last)
      end
    end
  end

  @doc """
  Timer, `width` bit down-counter. Ports: `start` (load `value` and run;
  restarts a running timer), `value` (width), `busy`, `done` (one-cycle
  pulse in the cycle after the count reached zero). `value` cycles pass
  between `start` and `done` (`busy` is high for `value` cycles after the
  start cycle). With `periodic: true` it reloads itself and `done` pulses
  every `value + 1` cycles until `stop` (an extra input) is seen; a `done`
  already due still pulses, and `start` restarts it.
  """
  def timer(width, opts \\ []) do
    periodic = Keyword.get(opts, :periodic, false)

    module "timer_#{width}#{if periodic, do: "_periodic", else: ""}" do
      start = input(:start, 1)
      value = input(:value, width)
      stop = if periodic, do: input(:stop, 1)
      busy = output(:busy, 1)
      done = output(:done, 1, reset: 0)
      left = reg(:left, width)
      run = reg(:run, 1)
      reload = reg(:reload, width)
      stopped = if periodic, do: reg(:stopped, 1)

      sync do
        done <~ 0

        if start do
          if periodic, do: stopped <~ 0
          left <~ value
          reload <~ value
          run <~ (value != 0)
          done <~ (value == 0)
        else
          if run do
            if left == 1 do
              done <~ 1
              run <~ 0
            end

            left <~ sub_wrap(left, 1)
          end

          if periodic do
            if stop do
              run <~ 0
              stopped <~ 1
            else
              if done and not stopped do
                left <~ reload
                run <~ (reload != 0)
                done <~ (reload == 0)
              end
            end
          end
        end
      end

      busy <~ run
    end
  end

  @doc """
  Pulse stretcher. Ports: `pulse`, `out`. `out` is high for `cycles`
  cycles starting the cycle after a `pulse`; a new pulse restarts the
  count (retriggerable).
  """
  def pulse_stretcher(cycles) when cycles >= 1 do
    module "pulse_stretcher_#{cycles}" do
      pulse = input(:pulse, 1)
      out = output(:out, 1)
      left = reg(:left, bits(cycles + 1))

      sync do
        if pulse do
          left <~ cycles
        else
          if left != 0, do: left <~ sub_wrap(left, 1)
        end
      end

      out <~ (left != 0)
    end
  end

  @doc """
  Debouncer for an asynchronous input (button, switch). Ports: `in`
  (asynchronous), `out`, `rise`, `fall` (one-cycle pulses when `out`
  changes). The input goes through a `stages` (default 2) flip-flop
  synchroniser; `out` follows it once it has differed from `out` for
  `cycles` consecutive cycles. `init:` is the reset level of `out`.
  """
  def debouncer(cycles, opts \\ []) when cycles >= 1 do
    stages = Keyword.get(opts, :stages, 2)
    init = Keyword.get(opts, :init, 0)

    module "debouncer_#{cycles}_s#{stages}_i#{init}" do
      din = input(:in, 1, domain: :async)
      out = output(:out, 1, reset: init)
      rise = output(:rise, 1)
      fall = output(:fall, 1)
      sync_in = instance(:sync, CDC.sync_ff(stages: stages), domains: [dst: :sys])
      sync_in.d <~ din
      stable = reg(:stable, bits(cycles + 1))
      prev = reg(:prev, 1, reset: init)

      sync do
        prev <~ out

        if sync_in.q == out do
          stable <~ 0
        else
          if stable >= cycles - 1 do
            out <~ sync_in.q
            stable <~ 0
          else
            stable <~ add_wrap(stable, 1)
          end
        end
      end

      rise <~ (out and not prev)
      fall <~ (prev and not out)
    end
  end

  @doc """
  LED blinker: `out` is high for the first `on` of every `period` cycles
  after reset. Port: `out`.
  """
  def blinker(period, on, _opts \\ []) when on in 1..period//1 do
    module "blinker_#{period}_#{on}" do
      out = output(:out, 1)
      phase = reg(:phase, bits(period))

      sync do
        if phase == period - 1, do: phase <~ 0, else: phase <~ add_wrap(phase, 1)
      end

      out <~ (phase < on)
    end
  end

  @doc """
  Heartbeat LED: a repeating `pattern` of `steps` bits (bit 0 first, the
  default is a double pulse in 16 steps), one step every `step_cycles`
  cycles. Port: `out`. At 125 MHz, `step_cycles: 7_812_500` gives a 1 s
  period.
  """
  def heartbeat(step_cycles, opts \\ []) when step_cycles >= 1 do
    steps = Keyword.get(opts, :steps, 16)
    pattern = Keyword.get(opts, :pattern, 0b0000_0000_0110_0011)

    module "heartbeat_#{step_cycles}_#{steps}_#{pattern}" do
      out = output(:out, 1)
      phase = reg(:phase, bits(step_cycles))
      shift = reg(:shift, steps, reset: pattern)
      last = wire(:last, phase == step_cycles - 1)

      sync do
        if last do
          phase <~ 0
          shift <~ cat([shift[0], shift[1..(steps - 1)]])
        else
          phase <~ add_wrap(phase, 1)
        end
      end

      out <~ shift[0]
    end
  end

  defmodule Model do
    @moduledoc "Cycle-accurate models of `ExHdlCores.Util`; see there."
    import Bitwise

    @doc false
    def run(init, stim, step) do
      {outs, _} =
        Enum.map_reduce(stim, init, fn inputs, st ->
          {st, out} = step.(st, inputs)
          {out, st}
        end)

      outs
    end

    def counter(width, opts, stim) do
      max = Keyword.get(opts, :max, (1 <<< width) - 1)
      down = Keyword.get(opts, :down, false)
      edge = if down, do: 0, else: max
      start = if down, do: max, else: 0

      run(start, stim, fn c, i ->
        next =
          cond do
            i.clear == 1 -> start
            i.en == 0 -> c
            c == edge -> start
            down -> c - 1
            true -> c + 1
          end

        {next, %{count: c, tc: if(c == edge, do: 1, else: 0)}}
      end)
    end

    def prescaler(div, stim) do
      run(0, stim, fn p, i ->
        last = p == div - 1
        tick = if i.en == 1 and last, do: 1, else: 0
        next = if i.en == 1, do: if(last, do: 0, else: p + 1), else: p
        {next, %{tick: tick}}
      end)
    end

    def pulse_stretcher(cycles, stim) do
      run(0, stim, fn l, i ->
        next =
          cond do
            i.pulse == 1 -> cycles
            l > 0 -> l - 1
            true -> 0
          end

        {next, %{out: if(l != 0, do: 1, else: 0)}}
      end)
    end

    def timer(opts, stim) do
      periodic = Keyword.get(opts, :periodic, false)

      run(%{left: 0, run: 0, reload: 0, done: 0, stopped: 0}, stim, fn s, i ->
        out = %{busy: s.run, done: s.done}
        next = %{s | done: 0}

        next =
          if i.start == 1 do
            %{
              next
              | left: i.value,
                reload: i.value,
                run: b(i.value != 0),
                done: b(i.value == 0),
                stopped: 0
            }
          else
            next =
              if s.run == 1 do
                n = %{next | left: s.left - 1}
                if s.left == 1, do: %{n | done: 1, run: 0}, else: n
              else
                next
              end

            cond do
              periodic and i.stop == 1 ->
                %{next | run: 0, stopped: 1}

              periodic and s.done == 1 and s.stopped == 0 ->
                %{next | left: s.reload, run: b(s.reload != 0), done: b(s.reload == 0)}

              true ->
                next
            end
          end

        {next, out}
      end)
    end

    defp b(true), do: 1
    defp b(false), do: 0

    @doc "Models the debouncer with a synchronous input (`in` already past the synchroniser delay: the model delays it by `stages`)."
    def debouncer(cycles, opts, stim) do
      stages = Keyword.get(opts, :stages, 2)
      init = Keyword.get(opts, :init, 0)
      pipe = List.duplicate(0, stages)

      run({pipe, init, 0, init}, stim, fn {pipe, out, stable, prev}, i ->
        q = List.last(pipe)
        outs = %{out: out, rise: b(out == 1 and prev == 0), fall: b(prev == 1 and out == 0)}
        pipe = [i.in | Enum.drop(pipe, -1)]

        {out2, stable2} =
          cond do
            q == out -> {out, 0}
            stable >= cycles - 1 -> {q, 0}
            true -> {out, stable + 1}
          end

        {{pipe, out2, stable2, out}, outs}
      end)
    end

    def blinker(period, on, stim) do
      run(0, stim, fn p, _ ->
        {rem(p + 1, period), %{out: b(p < on)}}
      end)
    end

    def heartbeat(step_cycles, opts, stim) do
      steps = Keyword.get(opts, :steps, 16)
      pattern = Keyword.get(opts, :pattern, 0b0000_0000_0110_0011)

      run({0, pattern}, stim, fn {p, sh}, _ ->
        out = %{out: band(sh, 1)}

        if p == step_cycles - 1 do
          rot = bor(bsr(sh, 1), bsl(band(sh, 1), steps - 1))
          {{0, rot}, out}
        else
          {{p + 1, sh}, out}
        end
      end)
    end
  end
end
