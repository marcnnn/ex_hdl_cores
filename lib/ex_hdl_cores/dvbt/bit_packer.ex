defmodule ExHdlCores.DVBT.BitPacker do
  @moduledoc """
  Bits to bytes, first bit in bit 7 (`ExSdr.Comm.Bits.pack/1`): the glue
  between the Viterbi decoder (one decoded bit per beat) and
  `ExHdlCores.DVBT.OuterDecoder` (bytes). Eight beats make a byte; no
  `tlast`, the bit counter runs from reset. One bit per clock in, a byte
  held in an output register, `s_axis_tready` is high while the register is
  free or being taken.
  """
  use ExHdl.RTL
  alias ExHdlCores.AXIS

  @doc "Elaborated packer: `s_axis` (1 bit), `m_axis` (8 bits)."
  def build do
    module "dvbt_bit_packer" do
      s = slave(:s_axis, AXIS.iface(data: 1, keep: false, last: false))
      m = master(:m_axis, AXIS.iface(data: 8, keep: false, last: false))
      shift = reg(:shift, 7, reset: nil)
      count = reg(:count, 3)
      out_valid = reg(:out_valid, 1)
      out = reg(:out, 8, reset: nil)

      m.tvalid <~ out_valid
      m.tdata <~ out
      take = wire(:take, s.tvalid and (m.tready or not out_valid))
      s.tready <~ (m.tready or not out_valid)

      sync do
        if m.tready, do: out_valid <~ 0

        if take do
          shift <~ cat([shift[0..5], s.tdata])
          count <~ add_wrap(count, 1)

          if count == 7 do
            out <~ cat([shift, s.tdata])
            out_valid <~ 1
          end
        end
      end
    end
  end
end
