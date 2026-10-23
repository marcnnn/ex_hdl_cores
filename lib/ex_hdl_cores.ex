defmodule ExHdlCores do
  @moduledoc """
  Generic, vendor-neutral hardware IP built on `ExHdl.RTL`. Each block is a
  function returning an `ExHdl.RTL.Module`, parameterised by Elixir
  arguments, with a BEAM reference model; tests check the generated RTL
  against the model in `ExHdl.RTL.Sim` and, with Verilator, against
  `ExHdl.RTL.Cosim`.

    * `ExHdlCores.CRC` - any polynomial, N bytes per cycle, `tkeep`
    * `ExHdlCores.Checksum` - Internet checksum adder tree
    * `ExHdlCores.Scrambler` - scramblers and PRBS generators
    * `ExHdlCores.ByteShift` - byte-lane shifter by runtime offset
    * `ExHdlCores.FIFO` - synchronous, asynchronous, AXI4-Stream, packet FIFOs
    * `ExHdlCores.AXIS` - skid buffer, width converters, merge, packet mux, broadcast, demux
    * `ExHdlCores.AXIL` - AXI4-Lite to cfg bus bridge, 1-to-N interconnect
    * `ExHdlCores.Arbiter` - fixed priority, round robin, packet-aware hold
    * `ExHdlCores.Util` - counter, prescaler, timer, pulse stretcher,
      debouncer, blinker, heartbeat
    * `ExHdlCores.Resources` - Yosys numbers (`mix ex_hdl_cores.resources`)
  """
end
