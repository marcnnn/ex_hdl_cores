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

## 4. Found while writing the AXI4-Lite blocks, checksum and packet mux

* `==` and `!=` are hardware operators inside `module/3` like `if`, so a
  generator that tests an optional handle (`if acc == nil`) fails with
  `not a hardware expression: nil`. Use `is_nil/1` or `case`. The message
  could say that `==` is the hardware comparison here.

      module "m" do
        a = input(:a, 1)
        y = output(:y, 1)
        x = a                              # a handle that may also be nil in generator code
        if x == nil, do: y <~ a, else: y <~ 0   # WidthError: not a hardware expression: nil
      end

* `mux/2` (hardware) is imported by `use ExHdl.RTL`, so a library cannot
  name a public block `mux/2`; `ExHdlCores.AXIS.packet_mux/2` is spelled
  that way for this reason (same family as the `sync` point above).
* Forwarding every data port of an instance to a top-level port (a top
  that hosts a user-supplied slave module) is a hand-written loop over
  `mod.ports`; instance ports being wires `<inst>_<port>` means the
  instance name must not equal the prefix of the re-exported ports
  (`output(:x_y, 1) <~ i.y` for instance `x` raises `x_y is declared
  twice`). An `expose/2` helper would remove both.

## Migration of local copies to the shared blocks

The sibling repos were not edited. Steps for their owners:

* **ex_net, MAC CRC** (`ExNet.RTL.CRC32.next/3`, `next_keep/4`):
  `ExHdlCores.CRC.next(:crc32, state, data, keep, bytes)` is the same
  expression (`keep` is `nil` for a full word); `CRC.final(:crc32, state)`
  gives `crc`. Note the `zero_keep: :one_byte` behaviour of `ExNet.RTL.CRC32`
  is the standalone module's option; inline, `keep = 0` selects nothing, so
  OR a 1 into `keep[0]` (`keep ||| 1`) where the MAC relied on it. Then
  `ExNet.RTL.CRC32` reduces to `build/1` (already a `CRC.build` call) and
  `ExNet.CRC32.matrices/1` can go.
* **ex_net, 1000BASE-X** (`ExNet.RTL.PCS1000X.build_rx/0`): replace the
  `p1`/`p2`/`shift_r`/`algn` block by `instance(:u_align,
  CommaAligner.build())` with `code <- rx_code10`, `lock <- sync` (the
  core's registered `sync`; it feeds back, so keep the `sync` signal
  declared before the instance), `aligned -> core code`, `shift -> shift`.
  Same latency (`aligned` is the `algn` register).
* **ex_net, tests**: `test/support/axis_source.ex` (`ExNet.AxisSource`)
  becomes `ExHdlCores.AxisDriver.run/2`; its `plan` with gaps and aborts
  (underrun) is not covered, keep that part locally or drive `drive/2`
  with beats whose `tvalid` the test shapes through `pre:`. `Tb.drive/2`
  style loops elsewhere become `AxisDriver.drive/2`.
* **ex_net, `ExNet.RTL.Classifier`**: the 12 beat `hdr0..hdr11` capture
  becomes `HeaderCapture.build(header: 90, data: 64)` (`hdr`, `hdr_len`,
  `hdr_valid`, `hdr_start` replace the local index and event wires).
  The 14 stage delay line and the result ring stay local (a packet FIFO
  with the verdict as sideband would replace them; not part of this block).
* **ex_ptp / ex_aes67 / ex_pcie**: no local copies of these four found
  (grep for `comma`, `hdr` capture, `axis_source`); the test driver is
  usable for their stream tests as well.

Not done: the classifier delay line, checksum tree (see `Checksum`) and
byte shifters (see `ByteShift`) were already shared earlier.
