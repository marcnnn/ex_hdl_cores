defmodule ExHdlCores do
  @moduledoc """
  Generic, vendor-neutral hardware IP built on `ExHdl.RTL`. Each block is a
  function returning an `ExHdl.RTL.Module`, parameterised by Elixir
  arguments, with a BEAM reference model; tests check the generated RTL
  against the model in `ExHdl.RTL.Sim` and, with Verilator, against
  `ExHdl.RTL.Cosim`.

    * `ExHdlCores.CRC` - any polynomial, N bytes per cycle, `tkeep`
    * `ExHdlCores.FIFO` - synchronous, asynchronous, AXI4-Stream, packet FIFOs
    * `ExHdlCores.AXIS` - skid buffer, width converters, merge, broadcast, demux
    * `ExHdlCores.Arbiter` - fixed priority, round robin, packet-aware hold
    * `ExHdlCores.Util` - counter, prescaler, timer, pulse stretcher,
      debouncer, blinker, heartbeat
    * `ExHdlCores.Resources` - Yosys numbers (`mix ex_hdl_cores.resources`)
  """
end
