# ExHdlCores

Generic, vendor-neutral hardware IP written with ExHdl's RTL DSL
(`ExHdl.RTL`). Each block is a function that returns an elaborated module
(`%ExHdl.RTL.Module{}`), parameterised by ordinary Elixir arguments. Every
block has a BEAM reference model and is checked three ways: the generated
RTL in the BEAM simulator against the model, the same RTL in Verilator
against the BEAM simulator (`ExHdl.RTL.Cosim`, tag `:verilator`), and
Verilator lint with `-Wall`. Stimulus is random (StreamData), including
random valid and ready on every stream port.

Status: implemented and tested, nothing synthesised in Vivado yet. The
resource numbers below are from Yosys. The consumers are ex_net, ex_ptp,
ex_aes67 and ex_pcie.

## Blocks

| Module | Blocks |
|---|---|
| `ExHdlCores.CRC` | `build/2`: any width, polynomial, reflection, init, final XOR; N bytes per cycle with `tkeep` |
| `ExHdlCores.FIFO` | `sync_fifo/1`, `async_fifo/1`, `axis/1`, `axis_async/1`, `packet/1` |
| `ExHdlCores.AXIS` | `skid/1`, `upsize/1`, `downsize/1`, `convert/1`, `merge/2`, `broadcast/2`, `demux/2` |
| `ExHdlCores.Arbiter` | `fixed/2`, `round_robin/2` (with optional packet hold) |
| `ExHdlCores.Util` | `counter/2`, `prescaler/2`, `timer/2`, `pulse_stretcher/1`, `debouncer/2`, `blinker/3`, `heartbeat/2` |

```elixir
alias ExHdlCores.{CRC, FIFO, AXIS, Arbiter, Util}
alias ExHdl.RTL.{Sim, Cosim}

mod = CRC.build(:crc32, bytes: 8)            # %ExHdl.RTL.Module{}
ExHdl.Backends.SystemVerilog.RTL.generate(mod) # %{"crc32_..._b8k.sv" => "..."}

# inside another module: instantiate and connect
fifo = instance(:rx_fifo, FIFO.axis(data: 64, user: 1, depth: 1024))
```

Modules need distinct names per parameter set; the builders derive them
from the parameters (`fifo_sync_32x512_block_fwft`).

### CRC

```elixir
CRC.build(:crc32c, bytes: 4)
CRC.build([width: 16, poly: 0x1021, init: 0xFFFF], bytes: 2, keep: false)
CRC.compute(:crc32, "123456789")   #=> 0xCBF43926 (bit-serial reference)
CRC.matrices(:crc32, 4)            #=> %{state: [...], data: [...]} XOR masks
```

Parameters are a preset (`CRC.presets/0`: `:crc32`, `:crc32c`,
`:crc32_bzip2`, `:crc32_mpeg2`, `:crc16_ccitt_false`, `:crc16_xmodem`,
`:crc16_kermit`, `:crc16_arc`, `:crc16_modbus`, `:crc8`, `:crc5_usb`,
`:crc64_xz`), a `%CRC{}` or keywords `width:`, `poly:`, `init:`, `refin:`,
`refout:`, `xorout:` (plus `preset:` as the base). The state is the
Rocksoft register; one word of `k` bytes is a linear map of (state, data),
derived by running the bit-serial algorithm on unit vectors, and the
hardware is one XOR network per possible byte count.

Ports: `data` (8 * bytes, byte 0 low), `keep` (bytes; the highest set bit
is the byte count of a partial last word), `valid`, `clear` (restart from
`init` before this word), `crc` (the CRC of everything since `clear`,
registered state with reflection and final XOR). Tests: all presets
against their catalogue check values, CRC-32 against `:erlang.crc32/1`,
CRC-32C and CRC-16/CCITT-FALSE check values in hardware, random width
(3..40), polynomial, init, final XOR, reflection, bus width (1..5 bytes),
random frame lengths and gaps against the bit-serial model.

### FIFOs

```elixir
FIFO.sync_fifo(width: 32, depth: 512)                         # BRAM, FWFT
FIFO.sync_fifo(width: 16, depth: 32, style: :distributed, fwft: false,
               almost_full: 28, almost_empty: 4)
FIFO.async_fifo(width: 64, depth: 512, count: true)          # clk_wr / clk_rd
FIFO.axis(data: 64, user: 1, depth: 2048)                    # s_axis -> m_axis
FIFO.axis_async(data: 32, depth: 256)
FIFO.packet(data: 64, user: 1, depth: 2048, err_bit: 0)      # store and forward
```

Depths are powers of two. `style:` is `:block` (default), `:ultra` or
`:distributed`.

| Block | Ports |
|---|---|
| `sync_fifo` | `clk`, `rst_n`; `wr_en`, `wr_data`, `full`; `rd_en`, `rd_data`, `empty`, `rd_valid` (only `fwft: false`); `count` (`count: false` omits); `almost_full` (`count >= n`), `almost_empty` (`count <= n`) when requested |
| `async_fifo` | `clk_wr`, `rst_wr_n`, `wr_en`, `wr_data`, `full`; `clk_rd`, `rst_rd_n`, `rd_en`, `rd_data`, `empty`; `wr_count`, `rd_count` with `count: true` |
| `axis`, `axis_async` | `s_axis_*`, `m_axis_*` (the async one with `clk_wr`/`rst_wr_n` on the slave, `clk_rd`/`rst_rd_n` on the master side); `count`, `almost_*` as above |
| `packet` | `s_axis_*`, `m_axis_*`, `drop_bad`, `drop_full` (pulses), `level` |

Read semantics. With `fwft: true` `rd_data` shows the oldest entry while
`empty` is low and `rd_en` pops it. Distributed storage reads
combinationally. Block and UltraRAM need a synchronous read, so the FIFO
prefetches into the RAM output register: one extra cycle of latency, one
extra entry of capacity in the asynchronous FIFO (`depth + 1`), and a
combinational path from `rd_en` to the RAM enable. With `fwft: false`,
`rd_en` pops and `rd_data` is valid in the next cycle (`rd_valid`). Writes
while full and reads while empty are ignored.

Asynchronous FIFO reset. Each domain has a synchronous active-low reset.
Assert both together, hold them for at least `stages + 1` (3) cycles of the
slower clock (derive them from one asynchronous source with
`ExHdl.RTL.CDC.reset_sync/1` per domain), and do not push or pop before
both are released. The synchroniser flip-flops are reset too, so no stale
pointer survives. Resetting one side alone while the other operates
corrupts the pointer relationship.

Packet FIFO. A packet becomes readable only after its `tlast` beat is
stored and `tuser[err_bit]` was low on that beat; otherwise the whole
packet is dropped and its space reused. The reader never sees a partial
packet. With `drop_on_full: true` (default) `s_axis_tready` is always high,
as a MAC receiver needs: a packet that does not fit is dropped whole
(`drop_full` pulses once). With `drop_on_full: false` it backpressures,
and a packet longer than the FIFO blocks forever.

Tests: against an ideal queue model (`FIFO.Model`) cycle by cycle for
`count`, `full`, the almost flags, `empty` consistency, order and
`rd_valid` (depth 2..16, all styles, FWFT on and off); asynchronous FIFOs
with three clock ratios (no overflow, order, capacity, bounds on the fill
levels, drain); AXI4-Stream FIFOs with random valid/ready against the
packet list; the packet FIFO against "good packets in order" with the
`drop_bad` and `drop_full` counts, also with a FIFO smaller than the
packets.

### AXI4-Stream

Stream shape options on every block: `data:` bits (multiple of 8, default
32), `user:`, `id:`, `dest:` bits (0 = absent), `keep: false`,
`last: false`. Ports are `s_axis_<field>` / `m_axis_<field>` (`tdata`,
`tkeep`, `tlast`, `tuser`, `tid`, `tdest`, `tvalid`, `tready`); multi-port
blocks use `s0_axis`, `m1_axis`, .... Conventions: little-endian bytes,
`tkeep` contiguous from bit 0 and only partial on the last beat, no
`tstrb`.

| Block | Behaviour |
|---|---|
| `skid(kind: :skid)` | register slice, all outputs and `s_axis_tready` registered, full rate |
| `skid(kind: :forward)` | register on `tvalid` and payload only, `tready` passes through |
| `upsize(in_bytes:, out_bytes:)` | packs k beats into a word, partial last word with `tkeep`; `tuser` ORed, `tid`/`tdest` of the last beat |
| `downsize(in_bytes:, out_bytes:)` | splits a word into k beats, skips empty slices after the last byte, `tlast` on the last non-empty one, `tuser` repeated |
| `convert(in_bytes:, out_bytes:)` | picks the above (equal widths: skid), integer ratios only |
| `merge(n, packet: true, arbiter: :round_robin)` | n to 1, grant held until `tlast` (or per beat with `packet: false`), never changes while stalled |
| `broadcast(n)` | 1 to n; a beat is accepted when all outputs took it |
| `demux(n, dests: [...], drop_unknown: true)` | routes whole packets by the `tdest` of their first beat; other destinations are dropped (or stall) |

```elixir
AXIS.skid(data: 64, user: 1)
AXIS.upsize(in_bytes: 1, out_bytes: 8, user: 1)     # byte stream to 64 bit
AXIS.convert(in_bytes: 8, out_bytes: 4)
AXIS.merge(3, data: 64, user: 1)                    # s0_axis, s1_axis, s2_axis -> m_axis
AXIS.demux(2, data: 32, dest: 4, dests: [3, 7])
```

Tests (random packets, random valid and ready, the driver in
`test/support/tb.ex` checks that `tvalid` and the payload hold until
`tready` on every output): skid buffer beats equal input beats; the
converters against a word-by-word model including `tkeep`, `tuser` and
`tid` (ratios 2..4, bus widths 1..16 bytes); merge: all packets present,
whole, each input's order kept; broadcast: every output sees every
packet; demux: each output sees exactly the packets for its `tdest`.

### Arbiters

```elixir
Arbiter.fixed(4)
Arbiter.round_robin(8, hold: :packet)
```

Ports: `req` (n), `adv`, `grant` (one-hot, combinational), `idx`, `valid`.
`adv` marks the grant finished (a transfer, or the last beat of a packet).
Round robin gives priority to the requesters above the last granted one.
`hold: :packet` keeps the grant, even if the request drops, until `adv`.
Tested against the cycle-accurate `Arbiter.Model` with random request
patterns (n = 1..7).

### Utilities

| Block | Ports and behaviour |
|---|---|
| `Util.counter(width, max:, down:)` | `en`, `clear`, `count`, `tc` |
| `Util.prescaler(div)` | `en`, `tick` (every `div`-th enabled cycle) |
| `Util.timer(width, periodic:)` | `start`, `value`, (`stop`), `busy`, `done` (pulse) |
| `Util.pulse_stretcher(cycles)` | `pulse`, `out` (high `cycles` cycles after a pulse, retriggerable) |
| `Util.debouncer(cycles, stages:, init:)` | asynchronous `in` through a synchroniser, `out`, `rise`, `fall` |
| `Util.blinker(period, on)` | `out` high `on` of every `period` cycles |
| `Util.heartbeat(step_cycles, pattern:, steps:)` | `out`, a rotating bit pattern (default a double pulse), one step per `step_cycles` |

All with models in `Util.Model`, tested against them with random inputs.

## Resources

Yosys `synth_xilinx` (0.69), no Vivado: LUT counts are Yosys's estimate,
memory inference is what the tools will do. Reproduce with `mix
ex_hdl_cores.resources`. The table gives UltraScale+ (`xcup`, e.g. the XCKU3P); the last column
has the 7-series (`xc7`) LUT and LUTRAM counts where they differ. No
block uses SRLs or DSPs.

| Block | LUT | FF | LUTRAM | RAMB18 | URAM | xc7 LUT / LUTRAM |
|---|---|---|---|---|---|---|
| CRC-32, 1 B/cycle | 84 | 32 | 0 | 0 | 0 | same |
| CRC-32, 8 B/cycle + tkeep | 1555 | 32 | 0 | 0 | 0 | same |
| CRC-32C, 4 B/cycle + tkeep | 639 | 32 | 0 | 0 | 0 | same |
| CRC-16/CCITT-FALSE, 2 B/cycle + tkeep | 93 | 16 | 0 | 0 | 0 | same |
| sync FIFO 32 x 512, block, FWFT | 25 | 31 | 0 | 1 | 0 | 24 / 0 |
| sync FIFO 32 x 32, distributed, FWFT | 18 | 23 | 3 | 0 | 0 | 18 / 6 |
| sync FIFO 72 x 4096, UltraRAM, FWFT | 32 | 40 | 0 | 0 | 1 | n/a |
| async FIFO 32 x 512, block | 45 | 80 | 0 | 1 | 0 | 40 / 0 |
| async FIFO 8 x 16, distributed | 18 | 38 | 1 | 0 | 0 | 18 / 2 |
| AXIS FIFO 64 b + keep/last, 512 | 25 | 31 | 0 | 3 | 0 | 24 / 0 |
| packet FIFO 64 b, 2048 beats | 67 | 40 | 0 | 9 | 0 | same |
| AXIS skid buffer, 64 b | 77 | 148 | 0 | 0 | 0 | same |
| AXIS register slice (forward), 64 b | 1 | 74 | 0 | 0 | 0 | same |
| AXIS upsize 8 B to 16 B | 293 | 291 | 0 | 0 | 0 | same |
| AXIS downsize 16 B to 8 B | 77 | 147 | 0 | 0 | 0 | same |
| AXIS downsize 8 B to 1 B | 37 | 77 | 0 | 0 | 0 | same |
| AXIS merge 4 to 1, packet-aware, 64 b | 179 | 9 | 0 | 0 | 0 | same |
| AXIS broadcast 1 to 4, 64 b | 12 | 4 | 0 | 0 | 0 | same |
| AXIS demux 1 to 4 by tdest, 64 b | 11 | 3 | 0 | 0 | 0 | same |
| round-robin arbiter, 8, packet hold | 57 | 17 | 0 | 0 | 0 | same |
| fixed-priority arbiter, 8 | 13 | 0 | 0 | 0 | 0 | same |
| debouncer, 1M cycles | 10 | 24 | 0 | 0 | 0 | same |
| timer, 32 bit | 53 | 34 | 0 | 0 | 0 | same |

## Development

```sh
./scripts/checkout_siblings.sh   # path dependencies (../exhdl, ../nx_fixed)
mix test                         # BEAM tests; Verilator and Yosys tests run when installed
mix test --only verilator        # co-simulation and lint only
mix ex_hdl_cores.resources       # regenerate the resource table
```

`mix test` runs about 1 minute, most of it Yosys (`:yosys`) and the first
Verilator builds (cached under `_build/<env>/ex_hdl_sim`). `NEEDS.md`
lists what the RTL DSL still lacks, with reproducers.
