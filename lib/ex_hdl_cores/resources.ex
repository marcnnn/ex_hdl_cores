defmodule ExHdlCores.Resources do
  @moduledoc """
  Yosys resource estimates (`synth_xilinx`) of representative instances,
  for the README: `mix ex_hdl_cores.resources`. Numbers are Yosys's, not
  Vivado's: expect LUT counts within tens of percent, memory inference to
  match.
  """
  alias ExHdlCores.{AXIS, Arbiter, CRC, FIFO, Util}

  @doc "`[{label, module}]`."
  def instances do
    [
      {"CRC-32, 1 B/cycle", CRC.build(:crc32)},
      {"CRC-32, 8 B/cycle + tkeep", CRC.build(:crc32, bytes: 8)},
      {"CRC-32C, 4 B/cycle + tkeep", CRC.build(:crc32c, bytes: 4)},
      {"CRC-16/CCITT-FALSE, 2 B/cycle + tkeep", CRC.build(:crc16_ccitt_false, bytes: 2)},
      {"sync FIFO 32 x 512, block, FWFT", FIFO.sync_fifo(width: 32, depth: 512)},
      {"sync FIFO 32 x 32, distributed, FWFT",
       FIFO.sync_fifo(width: 32, depth: 32, style: :distributed)},
      {"sync FIFO 72 x 4096, UltraRAM, FWFT",
       FIFO.sync_fifo(width: 72, depth: 4096, style: :ultra)},
      {"async FIFO 32 x 512, block", FIFO.async_fifo(width: 32, depth: 512)},
      {"async FIFO 8 x 16, distributed",
       FIFO.async_fifo(width: 8, depth: 16, style: :distributed)},
      {"AXIS FIFO 64 b + keep/last, 512", FIFO.axis(data: 64, depth: 512)},
      {"packet FIFO 64 b, 2048 beats", FIFO.packet(data: 64, depth: 2048)},
      {"AXIS skid buffer, 64 b", AXIS.skid(data: 64)},
      {"AXIS register slice (forward), 64 b", AXIS.skid(data: 64, kind: :forward)},
      {"AXIS upsize 8 B to 16 B", AXIS.upsize(in_bytes: 8, out_bytes: 16)},
      {"AXIS downsize 16 B to 8 B", AXIS.downsize(in_bytes: 16, out_bytes: 8)},
      {"AXIS downsize 8 B to 1 B", AXIS.downsize(in_bytes: 8, out_bytes: 1)},
      {"AXIS merge 4 to 1, packet-aware, 64 b", AXIS.merge(4, data: 64)},
      {"AXIS broadcast 1 to 4, 64 b", AXIS.broadcast(4, data: 64)},
      {"AXIS demux 1 to 4 by tdest, 64 b", AXIS.demux(4, data: 64, dest: 2)},
      {"round-robin arbiter, 8, packet hold", Arbiter.round_robin(8, hold: :packet)},
      {"fixed-priority arbiter, 8", Arbiter.fixed(8)},
      {"debouncer, 1M cycles", Util.debouncer(1_000_000)},
      {"timer, 32 bit", Util.timer(32)}
    ]
  end

  @doc "Runs Yosys for every instance and family (UltraRAM instances only for `xcup`); `{label, family, {:ok, map} | {:error, e}}`."
  def run(families \\ ["xc7", "xcup"]) do
    for {label, mod} <- instances(), family <- families, family == "xcup" or not uram?(mod) do
      sources = ExHdl.Backends.SystemVerilog.RTL.generate(mod)
      {label, family, ExHdl.Synth.Yosys.utilization(sources, mod.name, family: family)}
    end
  end

  defp uram?(mod), do: Enum.any?(mod.memories, &(&1.style == :ultra))

  @doc "Markdown table of `run/1` results."
  def table(results) do
    rows =
      for {label, family, res} <- results do
        case res do
          {:ok, u} ->
            "| #{label} | #{family} | #{u.lut} | #{u.ff} | #{u.lutram} | #{u.srl} | #{u.bram18} | #{Map.get(u, :uram, 0)} | #{u.dsp} |"

          {:error, e} ->
            "| #{label} | #{family} | error: #{String.slice(inspect(e), 0, 40)} | | | | | | |"
        end
      end

    Enum.join(
      [
        "| Block | Family | LUT | FF | LUTRAM | SRL | RAMB18 | URAM | DSP |",
        "|---|---|---|---|---|---|---|---|---|" | rows
      ],
      "\n"
    )
  end
end
