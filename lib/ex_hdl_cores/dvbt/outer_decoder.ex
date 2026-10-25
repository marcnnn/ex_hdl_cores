defmodule ExHdlCores.DVBT.OuterDecoder do
  @moduledoc """
  The DVB-T outer decoder chain (ETSI EN 300 744, 4.3): Forney
  deinterleaver (I = 12, M = 17), Reed-Solomon RS(204, 188, t = 8) and
  energy dispersal descrambler, as `ExSdr.DVBT.Receiver.Stream` chains them
  after the Viterbi decoder: bytes in, transport stream packets out.

  Ports: `s_axis` (`tdata` 8, no `tlast`) takes the bytes of the Viterbi
  decoder, the first byte after reset being the first byte of a 204 byte
  packet (the sync byte of the interleaver's branch 0). `m_axis` gives 188
  byte packets with `tlast` and `tuser` = `{corrected, failed}` of the
  Reed-Solomon codeword (bit 0 failed, bit 1 corrected) on every beat. The
  outputs `stat_valid`, `stat_failed`, `stat_errors` pulse once per
  codeword (`ExHdlCores.ReedSolomon`), `aligned` is high once the first
  inverted sync byte (0xB8) has been seen and `realign` (a pulse) makes the
  descrambler look for the next one (`ExHdlCores.EnergyDispersal`).

  The first 2244 deinterleaver output bytes (empty delay lines) are dropped
  inside, so the first codeword is the first packet that went in; the
  descrambler then drops packets up to the first group start, as the
  receiver does. Nothing is aligned automatically on the input side: a
  change of byte alignment upstream needs a reset of the chain (and
  `ExHdlCores.ConvInterleaver`'s `framing` option if the upstream offers
  `tlast`).

  Modules: `deint`, `rs`, `descr` (instances). One byte per clock through
  the chain; `s_axis_tready` is high while the Reed-Solomon stage has room.
  """
  use ExHdl.RTL
  alias ExHdlCores.{AXIS, ConvInterleaver, EnergyDispersal, ReedSolomon}

  @doc "`{label, module}` of the blocks of the chain for the resource table (`ExHdlCores.Resources`)."
  def resource_instances do
    [
      {"Forney deinterleaver I = 12, M = 17, 204 byte packets (DVB-T)",
       ConvInterleaver.build(branches: 12, depth: 17, packet: 204, skip: 2244)},
      {"Reed-Solomon RS(204, 188) decoder, 4 codeword buffers", ReedSolomon.dvbt()},
      {"DVB energy dispersal descrambler", EnergyDispersal.build(user: 2)},
      {"DVB-T outer decoder (deinterleaver, RS, descrambler)", build()}
    ]
  end

  @doc "Elaborated chain; options `slots:` (Reed-Solomon codeword buffers, default 4)."
  def build(opts \\ []) do
    slots = Keyword.get(opts, :slots, 4)

    module "dvbt_outer_decoder" do
      s = slave(:s_axis, AXIS.iface(data: 8, keep: false, last: false))
      mo = master(:m_axis, AXIS.iface(data: 8, keep: false, user: 2))
      realign = input(:realign, 1)
      aligned = output(:aligned, 1)
      stat_valid = output(:stat_valid, 1)
      stat_failed = output(:stat_failed, 1)
      stat_errors = output(:stat_errors, 4)

      di =
        instance(
          :deint,
          ConvInterleaver.build(branches: 12, depth: 17, packet: 204, skip: 2244)
        )

      rs = instance(:rs, ReedSolomon.dvbt(slots: slots))
      de = instance(:descr, EnergyDispersal.build(user: 2))

      di.s_axis_tdata <~ s.tdata
      di.s_axis_tvalid <~ s.tvalid
      s.tready <~ di.s_axis_tready

      rs.s_axis_tdata <~ di.m_axis_tdata
      rs.s_axis_tvalid <~ di.m_axis_tvalid
      di.m_axis_tready <~ rs.s_axis_tready

      de.s_axis_tdata <~ rs.m_axis_tdata
      de.s_axis_tvalid <~ rs.m_axis_tvalid
      de.s_axis_tlast <~ rs.m_axis_tlast
      de.s_axis_tuser <~ rs.m_axis_tuser
      rs.m_axis_tready <~ de.s_axis_tready

      mo.tdata <~ de.m_axis_tdata
      mo.tvalid <~ de.m_axis_tvalid
      mo.tlast <~ de.m_axis_tlast
      mo.tuser <~ de.m_axis_tuser
      de.m_axis_tready <~ mo.tready

      de.realign <~ realign
      aligned <~ de.aligned
      stat_valid <~ rs.stat_valid
      stat_failed <~ rs.stat_failed
      stat_errors <~ rs.stat_errors
    end
  end
end
