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
ex_aes67 and ex_pcie (which uses `AXIS.packet_mux/2` and `AXIL.interconnect/2`).

## Blocks

| Module | Blocks |
|---|---|
| `ExHdlCores.CRC` | `build/2`: any width, polynomial, reflection, init, final XOR; N bytes per cycle with `tkeep`; `next/5` and `final/2` for an inline step inside another module; options that make it a drop-in for ex_net's `crc32_8` / `crc32_64` |
| `ExHdlCores.Checksum` | `build/1`: Internet checksum (RFC 1071) adder tree over N-byte words with `tkeep`; `window/3` and `fold/1` for use inside other modules |
| `ExHdlCores.Scrambler` | `build/1`: self-synchronising scrambler, descrambler and additive PRBS over N-bit words for any tap list; `matrix/3` turns any linear step function into an XOR network |
| `ExHdlCores.ByteShift` | `build/1`: byte-lane barrel shifter (left or right) by a runtime offset, with `tkeep`; `shift/4` for use inside other modules |
| `ExHdlCores.CommaAligner` | `build/1`: 8b/10b word alignment on a comma (K28.5), the offset freezes while `lock` is high; `ref/2` model |
| `ExHdlCores.HeaderCapture` | `build/1`: captures the first N bytes of each AXI4-Stream packet into a register while the stream passes unchanged |
| `ExHdlCores.ConvInterleaver` | `build/1`: Forney convolutional interleaver and deinterleaver for byte streams, any branches and depth, one byte per clock, the delay lines in one block RAM; `model/4` reference |
| `ExHdlCores.ReedSolomon` | `build/1`: RS decoder for any GF(2^m) code (field polynomial, n, k, first root, root step, shortening), one symbol per clock with several codewords in flight; `dvbt/0` is RS(204, 188) |
| `ExHdlCores.EnergyDispersal` | `build/1`: DVB energy dispersal descrambler for 188 byte packets; `model/1` reference |
| `ExHdlCores.DVBT.OuterDecoder` | `build/1`: deinterleaver, Reed-Solomon and descrambler chained as ex_sdr's DVB-T receiver does |
| `ExHdlCores.DVBT.Receiver` | `build/1`: the whole DVB-T 2k receiver, sc16 samples in, transport stream out: ex_hdl's OFDM front end with the hardware FFT, FIFO, Viterbi, bit packer and the outer decoder |
| `ExHdlCores.GF` | GF(2^m) reference arithmetic and XOR-network expressions (constant and general multipliers, inverse table) |
| `ExHdlCores.AxisDriver` | test driver: `run/2` frames in, frames out; `drive/2` on a `Sim` or a Verilator `Session`, random `tvalid`/`tready`, protocol checks |
| `ExHdlCores.FIFO` | `sync_fifo/1`, `async_fifo/1`, `axis/1`, `axis_async/1`, `packet/1` |
| `ExHdlCores.AXIS` | `skid/1`, `upsize/1`, `downsize/1`, `convert/1`, `merge/2`, `packet_mux/2`, `broadcast/2`, `demux/2` |
| `ExHdlCores.AXIL` | `cfg_bridge/1` (AXI4-Lite to `cfg_we/cfg_sel/cfg_addr/cfg_data` bus), `interconnect/2` (1 master to N slaves by address range) |
| `ExHdlCores.Arbiter` | `fixed/2`, `round_robin/2` (with optional packet hold) |
| `ExHdlCores.Viterbi` | `build/1`, `dvbt/1`: streaming Viterbi decoder (K, generators, puncturing patterns, hard or soft bits), bit for bit ex_sdr's streaming decoder; `ref/2` model |
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

Replacing ex_net's `ExNet.RTL.CRC32` (module `crc32_<8*bytes>`, inputs
`data`, `keep`, `valid`, `init`, outputs `state`, `crc`, `ok`):

```elixir
CRC.build(:crc32, bytes: 8, clear_port: :init, state: true, residue: true,
          zero_keep: :one_byte, name: "crc32_64")
CRC.build(:crc32, bytes: 1, clear_port: :init, state: true, residue: true,
          name: "crc32_8")                       # no keep port, as in ex_net
```

`clear_port:` renames `clear`; `state: true` adds `state`, the register in
reflected notation before the final XOR; `residue: true` (or an integer)
adds `ok`, `state == CRC.residue(:crc32)` (0xDEBB20E3); `zero_keep:
:one_byte` counts `valid` with `keep = 0` as one byte as ex_net does (the
default ignores the word). `crc` is the CRC-32 of the bytes so far
(`:erlang.crc32/1`), FCS bytes are `crc` little endian. `test/crc_compat_test.exs`
runs both on random `{data, nbytes, valid, init}` cycles against a
reflected bit-serial model with ex_net's expectations (outputs show the
register one cycle after the word; a frame with its FCS ends in the
residue), in the BEAM simulator and Verilator. The hand-written ex_net
module is about 1580 LUT at 64 bit; this one is 1551 (resource table).

### Internet checksum

```elixir
Checksum.build(bytes: 8)                 # accumulator, data/keep/valid/clear -> sum, csum
Checksum.build(bytes: 64, pipeline: 1)   # register after the adder tree
Checksum.sum(bin); Checksum.csum(bin)    # reference on binaries

# inside a module: folded sum of the masked words of one bus word
sum16 = Checksum.window(data, keep, 8)
```

Ones' complement sum of 16-bit words in network byte order (byte 0 of the
packet is the high byte of word 0), `bytes` per cycle (even), bytes with
a low `keep` bit count as zero, which pads an odd last byte on the right.
The words of a beat go through a balanced adder tree, `fold/1` brings the
result to 16 bits with end-around carry, and the accumulator folds again.
`sum` is canonical like the reference (0 only for all-zero input), `csum =
~sum` is the checksum field value, 0 over a packet that includes its
correct checksum. Latency one cycle after the word (two with
`pipeline: 1`). Tests: RFC 1071 example, an IPv4 header, random frames
with random gaps and partial last words for 2, 4, 8 and 64 bytes per cycle
with and without the pipeline register, `window/3` inside a module,
Verilator.

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

Where it is used (`test/packet_fit_test.exs`):

* behind ex_net's MAC receiver, which cannot be stopped and flags a bad
  frame in `tuser[0]` of the `tlast` beat (4 bit `tuser`, status code in
  bits 3:1): `FIFO.packet(data: 64, user: 4, err_bit: 0, depth: 512)`.
  `s_axis_tready` is always high, the status of good frames arrives
  unchanged on their last beat, `drop_bad` counts FCS and receive errors.
* in front of ex_aes67's depacketiser (96 bit metadata in `tuser` on the
  first beat only): carry one more `tuser` bit as the error flag, set by
  the classifier on the `tlast` beat of a packet to discard:
  `FIFO.packet(data: 64, user: 97, err_bit: 96, depth: 512)`. Metadata
  stays attached to its packet; the FIFO ignores `tuser` except
  `err_bit`. 512 beats hold two 1500 byte packets; the depacketiser's
  banks sit behind it. The classifier's checksum result must be known by
  the `tlast` beat, otherwise drop the packet inside the classifier.

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
`last: false`, `keep_bits:` (width of `tkeep` when it is not one bit per
byte, e.g. one per DWord on a PCIe stream; only for blocks that pass
`tkeep` through: skid, FIFOs, merge, packet_mux, broadcast, demux). Ports are `s_axis_<field>` / `m_axis_<field>` (`tdata`,
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
| `packet_mux(n, arbiter:, register:, src:)` | `merge` for requesters that need answers: `m_axis_src` (source index of the beat), `done` (n bits, pulse on the transferred `tlast` of each source), skid buffer on the output |
| `broadcast(n)` | 1 to n; a beat is accepted when all outputs took it |
| `demux(n, dests: [...], drop_unknown: true)` | routes whole packets by the `tdest` of their first beat; other destinations are dropped (or stall) |

```elixir
AXIS.skid(data: 64, user: 1)
AXIS.upsize(in_bytes: 1, out_bytes: 8, user: 1)     # byte stream to 64 bit
AXIS.convert(in_bytes: 8, out_bytes: 4)
AXIS.merge(3, data: 64, user: 1)                    # s0_axis, s1_axis, s2_axis -> m_axis
AXIS.demux(2, data: 32, dest: 4, dests: [3, 7])
AXIS.packet_mux(2, data: 256, keep_bits: 8, user: 62, src: false)   # ex_pcie's RqMux
```

Tests (random packets, random valid and ready, the driver in
`test/support/tb.ex` checks that `tvalid` and the payload hold until
`tready` on every output): skid buffer beats equal input beats; the
converters against a word-by-word model including `tkeep`, `tuser` and
`tid` (ratios 2..4, bus widths 1..16 bytes); merge: all packets present,
whole, each input's order kept; broadcast: every output sees every
packet; demux: each output sees exactly the packets for its `tdest`; packet_mux:
whole packets, per-source order kept, `m_axis_src` right on every beat
(also through the `tuser` it travels in), one `done` pulse per packet and
source, with and without the output register, round robin and fixed.
`ExPcie.RTL.RqMux` is a wrapper of `packet_mux/2` now.

### AXI4-Lite

32-bit data, bundles of `ExHdl.RTL.Interface.axi_lite/1`.

```elixir
# ex_aes67 depacketiser: cfg_we, cfg_sel (2), cfg_addr (16), cfg_data (32); stat_addr/stat_lane read
AXIL.cfg_bridge(sel_bits: 2, addr_bits: 16, raddr_bits: idx_w + 3)
# ex_net classifier: cfg_we, cfg_addr, cfg_data
AXIL.cfg_bridge(sel_bits: 0, addr_bits: addr_w, read: false)

# one BAR, several defregs slaves
AXIL.interconnect([%{base: 0x0000, size: 0x4000},
                   %{base: 0x4000, size: 0x1000},
                   %{base: 0x8000, size: 0x0400}], addr_bits: 16)
```

`cfg_bridge/1`: the AXI byte address is `{sel, addr, 2'b00}`. Outputs are
registered and `cfg_we` is one cycle wide per write: `cfg_we`, `cfg_sel`
(`sel_bits > 0`), `cfg_addr`, `cfg_data`, `cfg_be` (`be: true`, otherwise
`wstrb` is ignored). The read bus (`read: true`, default) is `cfg_re`
(pulse), `cfg_rsel`, `cfg_raddr` (`raddr_bits`) and the input `cfg_rdata`,
due `rd_latency` cycles (default 1, a synchronous RAM) after the `cfg_re`
cycle. With `read: false` reads return 0. Responses are OKAY.
For ex_aes67's `stat_addr`/`stat_lane`: `stat_addr = cfg_raddr[3..]`,
`stat_lane = cfg_raddr[0..2]`, `stat_data` drives `cfg_rdata`.

`interconnect/2`: ranges are power-of-two sized (at least 4 bytes) and
aligned, disjoint. The master port is `s_axil`, slave `i` is `m<i>_axil`
with `log2(size)` address bits (the offset inside the range), so a
`defregs` slave with that `addr_width` plugs in unchanged. The route is
chosen when `awvalid` / `arvalid` is first seen and held until the
response, one transaction per direction, a read and a write may overlap.
Unmapped addresses are answered inside (`unmapped: :decerr`, response 3,
or `:slverr`; reads return 0). Cost: up to two cycles of latency per
access, no registers in the data path.

Tests: both against a transaction-level model (a map) with
`ExHdl.Regs.SimDriver` and random handshake delays; the interconnect with
two `defregs` slaves and a hand-written slave that accepts AW and W
separately and answers slowly, unmapped addresses and holes, a w1c
register behind it; Verilator on the recorded driver stimulus.

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

### Viterbi decoder

```elixir
Viterbi.dvbt()                       # K = 7, 171/133, rates 1/2 2/3 3/4 5/6 7/8, depth 128
Viterbi.build(k: 7, polys: [0o171, 0o133], depth: 128, puncture: [[[1], [1]]])
Viterbi.build(k: 5, polys: [0o23, 0o35], soft: 3, start: :unknown)
```

Ports: `s_axis_tdata` (8 bits, one code bit per beat in the low `soft`
bits, ex_sdr's 0/1 bytes), `tvalid`, `tready`, `tlast` (last code bit of
the stream), `s_axis_tuser` (puncturing pattern index of the stream, read
with its first bit; only with several patterns, `Viterbi.dvbt_rates/0` is
the order for `dvbt/1`); `m_axis_*` with one decoded bit per beat in bit 0
and `tlast` on the last bit of the stream.

A stream is what ex_sdr sees from `ExSdr.Comm.Convolutional.decoder/2` to
`flush/1` (`start:`, `depth:` and the code as parameters): `tlast` flushes,
completes a puncturing period with erasures, traces back from the best end
state and resets the decoder for the next stream. The output is the same
bits, including the first `depth` steps, the window schedule (a traceback
of `2 * depth` steps from the best state every `depth` steps, the oldest
`depth` bits issued), the tie breaks (lower predecessor in the ACS, lowest
state number for the best state) and the flush. The tests compare whole
streams with ex_sdr's decoder in the BEAM simulator and in Verilator
(every DVB-T rate, every stream length around the window sizes, noisy and
pure random input, random valid and ready, back-to-back streams with
different rates, K = 3, 4 (three outputs), 5, 7 and 9, `start: :unknown`),
and BEAM against Verilator on random inputs, cycle by cycle.

Structure: a depuncturer (one code bit per clock; the puncturing tables
select per pattern and phase which outputs of a step are received, the
others are erasures with branch cost 0), a branch metric register, 64
parallel radix-2 add-compare-select units (one trellis step per clock when
the input has the bits), a block RAM of survivor decisions (one 64 bit word
per step, a ring of `3 * depth` words), a scan for the best end state
every `depth` steps (`2^(K - 1)` clocks, the ACS waits), and a traceback
engine at one step per clock with two output buffers (the decoded bits
come out of the traceback newest first and are written to their place).
Path metrics are modular and need no normalisation: `w` bits with the
spread bound `2 * R + 1`, `R = (K - 1) * n * (2^soft - 1)` (6 bits for
DVB-T). Limitations: one code bit per beat on the input; the throughput is
`depth` decoded bits per `max(2 * depth, ACS time + 2^(K - 1) + a few)`
clocks: 2.0 clocks per decoded bit at rates 2/3 to 7/8 and 2.5 at rate
1/2 (the input takes two clocks per step), measured on 6000 bits: 40 to 50
Mbit/s decoded at 100 MHz, DVB-T needs at most 34.4 Mbit/s; input stalls while a traceback
runs, so put a FIFO in front. Soft decisions (`soft: q` bits per code bit,
0 a sure zero) have no ex_sdr counterpart; `ref/2` is the model (it
equals ex_sdr on hard bits). The decoder is not resettable per stream
other than by `tlast`; do not abandon a stream.

Yosys `synth_xilinx` (7-series, no placement), `depth: 128`:

| Instance | LUT | FF | CARRY4 | RAMB36 | LUTRAM |
|---|---|---|---|---|---|
| DVB-T, 5 rates (`dvbt/0`) | 1348 | 555 | 407 | 1 | 8 |
| 1/2 only, no puncturing | 1334 | 548 | 406 | 1 | 8 |
| DVB-T, `soft: 3` | 2091 | 769 | 604 | 1 | 8 |
| K = 9, 561/753, rate 1/2 | 5503 | 1966 | 1558 | 4 | 8 |

About 2.5 % of a Zynq-7020's LUTs and one of its 140 block RAM tiles.
Timing: a netlist walk of the Yosys result (0.46 ns clock to output, 0.12
ns per LUT, 0.4 ns per carry, 0.5 ns per net, 2.2 ns block RAM clock to
output, 0.1 ns setup; a coarse model, not Vivado) gives 5.9 ns for the
longest path (block RAM output through the 64:1 decision select into the
traceback state), 5.0 ns for the ACS (metric, add, compare, select) and
5.4 ns for the depuncturer's handshake chain: about 170 MHz, so 100 MHz
and more on a -1 part should close. Not run through Vivado.

### DVB-T outer decoder

Bytes from the Viterbi decoder in, transport stream packets out, bit-exact
with `ExSdr.DVBT.Receiver.Stream`'s back end (deinterleaver, Reed-Solomon,
descrambler), at one byte per clock.

```elixir
OuterDecoder.build()                          # the chain: s_axis -> m_axis, stat_*, realign, aligned
ConvInterleaver.build(branches: 12, depth: 17, packet: 204, skip: 2244)
ReedSolomon.dvbt()                            # RS(204, 188), 4 codeword buffers
ReedSolomon.build(m: 8, field_poly: 0x187, n: 255, k: 223, fcr: 112, prim: 11)   # CCSDS
EnergyDispersal.build(user: 2)
```

`ConvInterleaver`: a ring buffer per branch in one memory (1122 bytes for
DVB, one RAMB18), one address register per branch; a byte reads the oldest
byte of its ring and is written into that place one cycle later. Options
`mode:`, `packet:` (generates `tlast`), `framing: true` (`s_axis_tlast`
restarts the branch counter), `skip:` (drops the zeros of the empty delay
lines).

`ReedSolomon` (details in the moduledoc): syndromes by Horner's rule while
the codeword goes into a block RAM ring, inversionless Berlekamp-Massey with
`t + 1` shared multipliers (3 cycles per iteration, then the error
evaluator by replaying the discrepancy product), Chien search at one
position per clock with Forney's algorithm pipelined behind it, error values
into a second ring, output = data xor error value. Per codeword `tuser` =
`{corrected, failed}` on every output beat and a `stat_valid` /
`stat_failed` / `stat_errors` pulse; a failed codeword passes through
uncorrected. Every stage needs at most one codeword time, so codewords
follow each other with no gap at the input (4 buffers, latency about 480
cycles for DVB). Backpressure on the output stalls the input once the
buffers are full.

`EnergyDispersal`: PRBS `1 + x^14 + x^15`, restarted every 8 packets, sync
bytes replaced by `0x47`; packets are dropped until a first byte `0xB8`,
then the group position is counted blindly as the receiver does.

Differences from ex_sdr: none found in tests, except one deliberate corner.
The locator registers hold `t + 1` coefficients, so a word whose
Berlekamp-Massey register length exceeds `t` is flagged failed (data
unchanged) where ex_sdr may say "decoded, 0 corrections" or find roots; it
takes crafted syndromes (`test/reed_solomon_test.exs` builds one, random
garbage reaches it about once in 10^5 words).

Tests (BEAM simulator, and Verilator against the BEAM simulator under
random valid and ready): the deinterleaver and interleaver against
`ExSdr.Comm.ConvInterleaver` for random lengths, branches 2..6, depths 1..4
and DVB 12 x 17 with the startup skipped; the descrambler against
`ExSdr.DVBT.EnergyDispersal` with leading junk packets, `realign` and
`tuser`; the decoder against `ExSdr.Comm.ReedSolomon.decode/2` on clean,
1..t error, t + 1 .. 2t + 4 error and garbage words for DVB, a GF(16) code
(first root 1), a GF(32) code (first root 3, root step 2, shortened) and a
shortened CCSDS-style code (first root 112, root step 11), plus the
`decode_all` counts; throughput of back-to-back codewords; the whole chain
on a scrambled, RS-encoded, interleaved and convolutionally encoded
transport stream with bursts of code bit errors against
`Receiver.Stream.push_back/2` (same bytes, same corrected and failed
counts). A one-off run of 700 mixed DVB words (garbage, 8, 9, 10 to 20 and
17 errors, parity-only errors) under random valid and ready had no
mismatch.

### DVB-T receiver

sc16 samples in, transport stream packets out, bit-exact with
`ExSdr.DVBT.Receiver.Stream` (`front_end: :fixed`, `input: :sc16`, given
`freq_offset`: the first sample starts a superframe, acquisition stays in
software).

```elixir
{:ok, d} = ExHdlCores.DVBT.Receiver.build(constellation: :qpsk, code_rate: {1, 2})
d.module                                   # s_axis (sc16), m_axis (TS bytes), inc / phase0 / load, counters
{inc, phase0} = ExHdlCores.DVBT.Receiver.phase_words(freq_offset)
```

Chain: `ExHdl.OFDM.FrontEnd` (correction, guard removal, `ExHdl.FFT`,
equaliser, cell and bit deinterleavers, one code bit per beat) -> FIFO
(16384 x 1 bit, one RAMB18) -> `Viterbi.build` with the code rate's
puncturing pattern, `start: :unknown`, `depth: 128` -> `DVBT.BitPacker`
(first bit in bit 7, as `Bits.pack`) -> `DVBT.OuterDecoder`. The code bits
of the front end carry `tlast` per bit interleaver block; it is not passed
on, so the Viterbi decoder never flushes: it runs the sliding window of
`Receiver.Stream.push_back/2`, and a window of 128 steps (16 bytes) stays
inside until more bits arrive. Byte alignment is the same as ex_sdr's: the
first decoded bit is bit 7 of the first byte, the deinterleaver starts
with the first byte, the Reed-Solomon codewords are the 204 byte blocks
from there, and only the descrambler looks for a sync byte (the first
0xB8, then counting). Nothing is searched in between, so the bytes are
the same from the same point.

Ports: `s_axis` (`{im, re}` s16, one sample per beat; no `tlast`, the
radio cannot wait), `inc`, `phase0`, `load` (the frequency correction,
`phase_words/2`), `m_axis` (188 byte packets, `tlast`, `tuser` = `{corrected,
failed}`), `realign`, `aligned`, and 32 bit counters `packets` (codewords),
`rs_failed`, `rs_errors` (ex_sdr's `rs_corrected`), `overflow` (samples
offered while `s_axis_tready` was low), `blocks`, plus `fifo_level`,
`fifo_peak`, `viterbi_last` (never rises). Options: `:constellation`,
`:code_rate`, `:guard` (only `{1, 32}`: `ExSdr.DVBT.OFDM.ofdm/0` has no
other), `:fifo_depth`, `:slots`, `:spec`, `:name`. Backpressure on `m_axis`
stalls the chain up to `s_axis`; a stalled sample is a lost sample
(`overflow`).

Co-simulation (test/dvbt_receiver_test.exs, Verilator, closed loop in
test/support/dvbt_rx_tb.ex): ExSdr's transmitter and a channel with carrier
offset 0.37 and noise, 28 symbols of QPSK 1/2 at one sample per 10 clocks
and bytes accepted every cycle; QPSK 7/8, 16-QAM 2/3 and 64-QAM 3/4 at
low SNR with random output backpressure (corrected and failed codewords
in all three, same counts as ex_sdr: the hardware's `rs_errors` and
`rs_failed` equal `rs_corrected` and `rs_failed` of the stream state);
64-QAM 7/8. Every run gives the same bytes as `Receiver.Stream.push/2` (no
flush) on the same samples; the lint of the whole design under `-Wall`.

Throughput. The chain takes 9.14 Msamples/s at a 100 MHz clock (10.94
clocks per sample) in every mode: with the source as fast as the chain
accepts samples, the steady state is

| Mode | clocks per symbol | clocks per sample | limit |
|---|---|---|---|
| QPSK 1/2 | 3030 | 1.43 | front end, one code bit per clock (3024 per symbol) |
| 16-QAM 3/4 | 6054 | 2.87 | front end (6048 bits) |
| 64-QAM 1/2 | 9078 | 4.30 | front end (9072 bits) |
| 64-QAM 7/8 | 16000 | 7.6 | Viterbi, 2 clocks per decoded bit (7938 bits) |

The symbol takes 23100 clocks at the real rate, so the worst mode uses 70 %.
At one sample per 10 clocks nothing overflowed in any run; the FIFO peak was
637 bits for QPSK 1/2 and 3862 for 64-QAM 7/8 of 16384.

Latency, from the last sample of the symbol that holds the last code bit
the Viterbi window needs for a packet, to the first byte of that packet at
`m_axis` (QPSK 1/2, all 14 packets of the run): 7000 to 10400 clocks, 70 to
104 us at 100 MHz, a third to half a symbol. The streaming FFT alone is
4173 clocks, the equaliser needs the whole symbol and the Reed-Solomon
decoder the whole codeword (about 480 clocks and 204 bytes). On top of that
come the Forney deinterleaver's 2244 bytes (11 packets, about 2.2 symbols
of QPSK 1/2) and the Viterbi window, which are data delays and not part of
the figure above.

Yosys `synth_xilinx` (7-series), whole receiver with the 2048 point FFT:

| Mode | LUT | LUTRAM | SRL | FF | DSP48E1 | RAMB36 equiv. |
|---|---|---|---|---|---|---|
| QPSK 1/2 | 7339 | 148 | 605 | 6253 | 52 | 23 (12 RAMB36, 22 RAMB18) |
| 64-QAM 7/8 | 8071 | 148 | 655 | 6534 | 62 | 23.5 |

Zynq-7020 (53200 LUT, 106400 FF, 140 RAMB36, 220 DSP): QPSK 1/2 is 14 % of
the LUTs (15 % with LUTRAM and SRL), 5.9 % of the FFs, 16 % of the block RAM
and 24 % of the DSPs; 64-QAM 7/8 is 15 % (17 %), 6.1 %, 17 % and 28 %. Yosys
numbers, not Vivado's, and no timing run of the whole design: the parts
have their own estimates above and in ex_hdl's README (FFT, OFDM), all
aimed at 100 MHz.

Differences from ex_sdr: the Viterbi tail (see above) stays in the decoder
at the end of a stream where `Receiver.Stream.flush/1` decodes it; the
guard interval is fixed at 1/32 (ex_sdr's `ofdm/0` takes no guard); the
hardware does not chunk (ex_sdr works in groups of 4 symbols, so compare
at a multiple of 4 symbols). Acquisition, tracking and the choice of
`inc` / `phase0` are software. A change of code rate or constellation is a
new build (the tests do not switch at run time).

## Resources

Yosys `synth_xilinx` (0.69), no Vivado: LUT counts are Yosys's estimate,
memory inference is what the tools will do. Reproduce with `mix
ex_hdl_cores.resources`. The table gives UltraScale+ (`xcup`, e.g. the XCKU3P); the last column
has the 7-series (`xc7`) LUT and LUTRAM counts where they differ. No
block uses DSPs; only the Reed-Solomon decoder has SRLs (15, pipeline delays).

| Block | LUT | FF | LUTRAM | RAMB18 | URAM | xc7 LUT / LUTRAM |
|---|---|---|---|---|---|---|
| CRC-32, 1 B/cycle | 84 | 32 | 0 | 0 | 0 | same |
| CRC-32, 8 B/cycle + tkeep | 1555 | 32 | 0 | 0 | 0 | same |
| CRC-32C, 4 B/cycle + tkeep | 639 | 32 | 0 | 0 | 0 | same |
| CRC-16/CCITT-FALSE, 2 B/cycle + tkeep | 93 | 16 | 0 | 0 | 0 | same |
| CRC-32 as ex_net's `crc32_64` (state, ok, init) | 1551 | 32 | 0 | 0 | 0 | same |
| Internet checksum, 8 B/cycle + tkeep | 119 | 16 | 0 | 0 | 0 | same |
| Internet checksum, 64 B/cycle, pipelined | 1112 | 34 | 0 | 0 | 0 | same |
| sync FIFO 32 x 512, block, FWFT | 25 | 31 | 0 | 1 | 0 | 24 / 0 |
| sync FIFO 32 x 32, distributed, FWFT | 18 | 23 | 3 | 0 | 0 | 18 / 6 |
| sync FIFO 72 x 4096, UltraRAM, FWFT | 32 | 40 | 0 | 0 | 1 | n/a |
| async FIFO 32 x 512, block | 45 | 80 | 0 | 1 | 0 | 40 / 0 |
| async FIFO 8 x 16, distributed | 18 | 38 | 1 | 0 | 0 | 18 / 2 |
| AXIS FIFO 64 b + keep/last, 512 | 25 | 31 | 0 | 3 | 0 | 24 / 0 |
| packet FIFO 64 b, 2048 beats | 67 | 40 | 0 | 9 | 0 | same |
| packet FIFO 64 b + 97 b tuser, 512 beats | 58 | 34 | 0 | 5 | 0 | 59 LUT |
| AXIS skid buffer, 64 b | 77 | 148 | 0 | 0 | 0 | same |
| AXIS register slice (forward), 64 b | 1 | 74 | 0 | 0 | 0 | same |
| AXIS upsize 8 B to 16 B | 293 | 291 | 0 | 0 | 0 | same |
| AXIS downsize 16 B to 8 B | 77 | 147 | 0 | 0 | 0 | same |
| AXIS downsize 8 B to 1 B | 37 | 77 | 0 | 0 | 0 | same |
| AXIS merge 4 to 1, packet-aware, 64 b | 179 | 9 | 0 | 0 | 0 | same |
| AXIS packet mux 2 to 1, 256 b (ex_pcie RqMux), registered | 676 | 663 | 0 | 0 | 0 | same |
| AXIS broadcast 1 to 4, 64 b | 12 | 4 | 0 | 0 | 0 | same |
| AXIS demux 1 to 4 by tdest, 64 b | 11 | 3 | 0 | 0 | 0 | same |
| round-robin arbiter, 8, packet hold | 57 | 17 | 0 | 0 | 0 | same |
| fixed-priority arbiter, 8 | 13 | 0 | 0 | 0 | 0 | same |
| AXI4-Lite to cfg bus (2 sel, 16 addr, read) | 5 | 107 | 0 | 0 | 0 | same |
| AXI4-Lite interconnect, 1 to 3 | 87 | 13 | 0 | 0 | 0 | same |
| AXI4-Lite interconnect, 1 to 8, 16 bit address | 236 | 23 | 0 | 0 | 0 | same |
| debouncer, 1M cycles | 10 | 24 | 0 | 0 | 0 | same |
| timer, 32 bit | 53 | 34 | 0 | 0 | 0 | same |
| DVB-T deinterleaver I = 12, M = 17, 204 byte packets | 186 | 167 | 0 | 1 | 0 | 178 LUT |
| RS(204, 188) decoder, 4 codeword buffers | 1639 | 1028 | 0 | 2 | 0 | 1653 LUT |
| DVB energy dispersal descrambler | 48 | 33 | 0 | 0 | 0 | same |
| DVB-T outer decoder (the three above chained) | 1903 | 1228 | 0 | 3 | 0 | 1894 LUT |

Timing, estimated only (no place and route): the longest combinational path
after LUT6 mapping (Yosys `abc -lut 6`, `ltp`, flip-flops and RAM
outputs as path ends) is 6 LUT levels in the Reed-Solomon decoder (the
`wp - rp` buffer-full compare through `s_axis_tready` to the
enable of the syndrome registers), 4 in the deinterleaver and 4 in the
descrambler; the Galois field multiplier and XOR tree of the
Berlekamp-Massey lanes and the Chien sums stay within that. With the
Zynq-7000 -1 model of `ExHdl.Target.Timing` (0.6 ns per level including
routing) that is about 3.6 ns of logic, 4.5 to 5.5 ns with clock-to-output,
setup and the fan-out of `acc` (about 150 registers): 180 MHz or better
for the chain, so 100 MHz on a Zynq-7020 -1 has margin of about 2x. Vivado
has not run.

## Development

Sibling libraries come from a checkout next to this one when there is one
(`../exhdl` for ex_hdl, `../<name>` for the others), otherwise from GitHub.

```sh
mix test                         # BEAM tests; Verilator and Yosys tests run when installed
mix test --only verilator        # co-simulation and lint only
mix ex_hdl_cores.resources       # regenerate the resource table
```

`mix test` runs about 1 minute, most of it Yosys (`:yosys`) and the first
Verilator builds (cached under `_build/<env>/ex_hdl_sim`). `NEEDS.md`
lists what the RTL DSL still lacks, with reproducers.

## License

Apache-2.0, see `LICENSE`.
