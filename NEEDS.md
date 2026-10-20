# Wishes for ExHdl

Found while writing ex_hdl_cores. Each has a reproducer (run with
`mix run` in a project that depends on ex_hdl).

## 1. Yosys rejects `~` applied to a size cast

`~~~` of a wrapping operation is emitted as `~8'(a - 8'd1)`. Verilator
accepts it, Yosys' `read_verilog -sv` (0.69) fails with `Static cast with
zero or negative size!`. `8'(~a)` and `~(8'(a))` parse.

```elixir
use ExHdl.RTL

m =
  module "inv_wrap" do
    a = input(:a, 8)
    y = output(:y, 8)
    y <~ ~~~sub_wrap(a, 1)
  end

src = ExHdl.Backends.SystemVerilog.RTL.generate(m)
# assign y = 8'(~8'(a - 8'd1));
{:error, "yosys exited with 1:" <> _} = ExHdl.Synth.Yosys.utilization(src, "inv_wrap")
```

Wish: parenthesise casts (`~(8'(...))`) in the SV backend. ex_hdl_cores
works around it in `ExHdlCores.Arbiter` (XOR with all ones).

## 2. Unused instance outputs do not lint (and break `Cosim.build/2`)

The backend declares a wire `<inst>_<port>` for every instance output.
When the parent does not read it, `verilator -Wall` reports UNUSEDSIGNAL,
and `Cosim.build/2` fails. Unused own signals and ports get a lint
pragma; instance output wires do not. Leaving an output of a reusable
child unconnected is normal.

```elixir
use ExHdl.RTL

child =
  module "two_outs" do
    a = input(:a, 4)
    p = output(:p, 4)
    q = output(:q, 1)
    p <~ a
    q <~ reduce_or(a)
  end

top =
  module "top_unused" do
    a = input(:a, 4)
    y = output(:y, 4)
    u = instance(:u, child, connect: [a: a])
    y <~ u.p
  end

{:error, "verilator exited with 1:\n%Warning-UNUSEDSIGNAL:" <> _} = ExHdl.RTL.Cosim.build(top)
# ... Signal is not used: 'u_q'
```

Wish: emit the same `lint_off UNUSEDSIGNAL` pragma around instance output
wires that nothing reads (or leave the port unconnected, `.q()`).
ex_hdl_cores avoids it by letting `ExHdlCores.Arbiter` drop its optional
outputs (`ports: []`) and by omitting FIFO count outputs when unused.

## 3. Smaller points

* `use ExHdl.RTL` imports `sync/1` and `sync/2` (macros), so a library
  module cannot define `def sync(opts)`; FIFOs are `sync_fifo/1` and
  `async_fifo/1` for that reason. `switch`, `state`, `signal`, `domain`
  and `reg` have the same effect on public API names. An
  `import ExHdl.RTL, only: ...` list or a `use ExHdl.RTL, except: [...]`
  would help.
* `if x do ... end` outside `comb`/`sync` with a hardware `x` (for example
  `if acc, do: acc ||| t, else: t` over a reduce accumulator that starts
  as `nil`) raises a width error about the condition; the message is
  right, but a note that `if` is hardware inside `module/3` would help
  generator authors. Using `case` (Elixir semantics) fixes it.
* A module without any register has no `clk`/`rst_n` ports, so
  `Sim.reset/2` and test benches that always poke `rst_n` need a special
  case for combinational modules (the arbiters).
