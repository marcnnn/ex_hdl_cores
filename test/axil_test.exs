defmodule ExHdlCores.AXILTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use ExHdl.RTL

  alias ExHdl.Regs.SimDriver
  alias ExHdl.RTL.{Cosim, Sim}
  alias ExHdlCores.AXIL

  # -- register maps and a hand-written slave --------------------------------------------

  defmodule RegsA do
    use ExHdl.Regs

    defregs "axil_test_regs_a", addr_width: 8 do
      register :ctrl do
        field(:value, 0..31, :rw, reset: 0xA)
      end

      register :stat do
        field(:value, 0..31, :ro)
      end
    end
  end

  defmodule RegsC do
    use ExHdl.Regs

    defregs "axil_test_regs_c", addr_width: 12 do
      register :ctrl do
        field(:value, 0..31, :rw)
      end

      register :irq do
        field(:ev, 0..7, :w1c)
      end
    end
  end

  # Four 32-bit registers; AW and W are accepted independently, the response
  # takes two cycles and a read three: a slave that is not like `defregs`.
  defp slow_slave do
    module "axil_test_slow" do
      s = slave(:s_axil, Interface.axi_lite(addr: 4, data: 32))
      regs = for i <- 0..3, do: reg(:"r#{i}", 32)
      have_aw = reg(:have_aw, 1)
      have_w = reg(:have_w, 1)
      waddr = reg(:waddr, 2)
      wdata = reg(:wdata, 32)
      bwait = reg(:bwait, 2)
      bvalid = reg(:bvalid, 1)
      rwait = reg(:rwait, 2)
      rvalid = reg(:rvalid, 1)
      rdata = reg(:rdata, 32)
      raddr = reg(:raddr, 2)
      rbusy = reg(:rbusy, 1)

      s.awready <~ (not have_aw and not bvalid and bwait == 0)
      s.wready <~ (not have_w and not bvalid and bwait == 0)
      s.arready <~ not rbusy
      s.bvalid <~ bvalid
      s.bresp <~ 0
      s.rvalid <~ rvalid
      s.rresp <~ 0
      s.rdata <~ rdata

      both = wire(:both, have_aw and have_w)

      sync do
        if s.awvalid and s.awready do
          have_aw <~ 1
          waddr <~ s.awaddr[2..3]
        end

        if s.wvalid and s.wready do
          have_w <~ 1
          wdata <~ s.wdata
        end

        if both do
          for {r, i} <- Enum.with_index(regs), do: if(waddr == i, do: r <~ wdata)
          have_aw <~ 0
          have_w <~ 0
          bwait <~ 2
        end

        if bwait != 0 do
          bwait <~ sub_wrap(bwait, 1)
          if bwait == 1, do: bvalid <~ 1
        end

        if bvalid and s.bready, do: bvalid <~ 0

        if s.arvalid and s.arready do
          rbusy <~ 1
          raddr <~ s.araddr[2..3]
          rwait <~ 3
        end

        if rwait != 0 do
          rwait <~ sub_wrap(rwait, 1)

          if rwait == 1 do
            rvalid <~ 1
            rdata <~ mux(raddr, regs)
          end
        end

        if rvalid and s.rready do
          rvalid <~ 0
          rbusy <~ 0
        end
      end
    end
  end

  # -- cfg bus bridge --------------------------------------------------------------------

  defp cfg_top(opts) do
    sb = Keyword.fetch!(opts, :sel_bits)
    ab = Keyword.fetch!(opts, :addr_bits)
    be? = Keyword.get(opts, :be, false)
    bridge = AXIL.cfg_bridge(opts)

    module "axil_cfg_top_#{sb}_#{ab}_#{be?}_#{Keyword.get(opts, :rd_latency, 1)}" do
      s = slave(:s_axil, Interface.axi_lite(addr: sb + ab + 2, data: 32))
      writes = output(:writes, 16, reset: 0)
      b = instance(:b, bridge)
      connect(s, b.s_axil)

      depth = Bitwise.bsl(1, sb + ab)
      mem = memory(:store, width: 32, depth: depth)
      waddr = if sb > 0, do: cat([b.cfg_sel, b.cfg_addr]), else: b.cfg_addr
      raddr = if sb > 0, do: cat([b.cfg_rsel, b.cfg_raddr]), else: b.cfg_raddr

      if be?,
        do: write_port(mem, addr: waddr, data: b.cfg_data, en: b.cfg_we, be: b.cfg_be),
        else: write_port(mem, addr: waddr, data: b.cfg_data, en: b.cfg_we)

      # synchronous read: data one cycle after the `cfg_re` cycle
      b.cfg_rdata <~ read_port(mem, addr: raddr)

      sync do
        if b.cfg_we, do: writes <~ add_wrap(writes, 1)
      end
    end
  end

  defp new_driver(top, opts) do
    SimDriver.new(Sim.new(top), opts)
  end

  describe "cfg_bridge" do
    test "writes appear once on the bus and read back through the read bus" do
      top = cfg_top(sel_bits: 2, addr_bits: 4)
      d = new_driver(top, delays: 0..3, seed: 2)
      # {sel, addr} -> byte address
      a = fn sel, addr -> Bitwise.bsl(sel, 6) + 4 * addr end

      {:okay, d} = SimDriver.write(d, a.(0, 3), 0x1111_2222)
      {:okay, d} = SimDriver.write(d, a.(2, 3), 0x3333_4444)
      {:okay, d} = SimDriver.write(d, a.(3, 15), 0xFFFF_FFFF)
      assert SimDriver.peek(d, :writes) == 3

      assert {0x1111_2222, :okay, d} = SimDriver.read(d, a.(0, 3))
      assert {0x3333_4444, :okay, d} = SimDriver.read(d, a.(2, 3))
      assert {0xFFFF_FFFF, :okay, d} = SimDriver.read(d, a.(3, 15))
      assert {0, :okay, _} = SimDriver.read(d, a.(1, 3))
    end

    test "byte strobes with be: true, ignored without" do
      d = new_driver(cfg_top(sel_bits: 0, addr_bits: 4, be: true), [])
      {:okay, d} = SimDriver.write(d, 8, 0xAABBCCDD)
      {:okay, d} = SimDriver.write(d, 8, 0x11223344, 0b0101)
      assert {0xAA22CC44, :okay, _} = SimDriver.read(d, 8)

      d = new_driver(cfg_top(sel_bits: 0, addr_bits: 4), [])
      {:okay, d} = SimDriver.write(d, 8, 0xAABBCCDD)
      {:okay, d} = SimDriver.write(d, 8, 0x11223344, 0b0101)
      assert {0x11223344, :okay, _} = SimDriver.read(d, 8)
    end

    property "random reads and writes match a map, with random handshake delays" do
      check all(
              sb <- integer(0..2),
              ops <-
                list_of(tuple({boolean(), integer(0..63), integer(0..0xFFFF_FFFF)}),
                  min_length: 5,
                  max_length: 40
                ),
              seed <- integer(),
              max_runs: 12
            ) do
        top = cfg_top(sel_bits: sb, addr_bits: 4, rd_latency: 1)

        d = new_driver(top, delays: 0..3, seed: seed)
        limit = Bitwise.bsl(1, sb + 4)

        {_, d} =
          Enum.reduce(ops, {%{}, d}, fn {wr?, w, data}, {m, d} ->
            addr = rem(w, limit)

            if wr? do
              {:okay, d} = SimDriver.write(d, addr * 4, data)
              {Map.put(m, addr, data), d}
            else
              {v, :okay, d} = SimDriver.read(d, addr * 4)
              assert v == Map.get(m, addr, 0)
              {m, d}
            end
          end)

        assert SimDriver.peek(d, :writes) == Enum.count(ops, &elem(&1, 0))
      end
    end

    test "read-only and write-only bridges, rd_latency 0" do
      m = AXIL.cfg_bridge(sel_bits: 0, addr_bits: 6, read: false)
      refute Enum.any?(m.ports, &(&1.name == :cfg_re))
      d = new_driver(m, [])
      {:okay, d} = SimDriver.write(d, 4, 7)
      assert SimDriver.peek(d, :cfg_data) == 7
      assert SimDriver.peek(d, :cfg_addr) == 1
      assert {0, :okay, _} = SimDriver.read(d, 4)

      m0 = AXIL.cfg_bridge(addr_bits: 4, rd_latency: 0)
      d = new_driver(m0, []) |> SimDriver.poke(%{cfg_rdata: 0x55})
      assert {0x55, :okay, d} = SimDriver.read(d, 12)
      assert SimDriver.peek(d, :cfg_raddr) == 3
    end

    @tag :verilator
    @tag timeout: 300_000
    test "co-simulates" do
      for opts <- [
            [sel_bits: 2, addr_bits: 4],
            [sel_bits: 0, addr_bits: 5, be: true],
            [sel_bits: 1, addr_bits: 3, rd_latency: 1]
          ] do
        top = cfg_top(opts)
        d = new_driver(top, delays: 0..2, seed: 5)

        d =
          Enum.reduce(1..30, d, fn i, d ->
            a = rem(i * 7, Bitwise.bsl(1, opts[:sel_bits] + opts[:addr_bits])) * 4
            {_, d} = SimDriver.write(d, a, i * 0x01010101, rem(i, 15) + 1)
            {_, _, d} = SimDriver.read(d, a)
            d
          end)

        Cosim.assert_equivalent(top, SimDriver.stimulus(d))
      end
    end
  end

  # -- interconnect ----------------------------------------------------------------------

  @slaves [
    %{base: 0x0000, size: 0x100},
    %{base: 0x1000, size: 0x10},
    %{base: 0x4000, size: 0x1000}
  ]

  defp ic_top(unmapped \\ :decerr) do
    ic = AXIL.interconnect(@slaves, addr_bits: 16, unmapped: unmapped)

    module "axil_ic_top_#{unmapped}" do
      s = slave(:s_axil, Interface.axi_lite(addr: 16, data: 32))
      a_stat = input(:a_stat, 32)
      a_ctrl = output(:a_ctrl, 32)
      c_ctrl = output(:c_ctrl, 32)
      c_ev = output(:c_ev, 8)
      c_ev_set = input(:c_ev_set, 8)

      i = instance(:ic, ic)
      a = instance(:a, RegsA.rtl())
      b = instance(:b, slow_slave())
      c = instance(:c, RegsC.rtl())
      connect(s, i.s_axil)
      connect(i.m0_axil, a.s_axil)
      connect(i.m1_axil, b.s_axil)
      connect(i.m2_axil, c.s_axil)
      a.stat_value <~ a_stat
      a_ctrl <~ a.ctrl_value
      c_ctrl <~ c.ctrl_value
      c_ev <~ c.irq_ev
      c.irq_ev_set <~ c_ev_set
    end
  end

  defp read!(d, addr) do
    {v, resp, d} = SimDriver.read(d, addr)
    {v, resp, d}
  end

  describe "interconnect" do
    test "routes each range to its slave" do
      d = new_driver(ic_top(), delays: 0..2, seed: 1) |> SimDriver.poke(%{a_stat: 0xCAFE})
      assert {0xA, :okay, d} = read!(d, 0x0000)
      assert {0xCAFE, :okay, d} = read!(d, 0x0004)
      {:okay, d} = SimDriver.write(d, 0x0000, 0x1234)
      {:okay, d} = SimDriver.write(d, 0x1000, 0xB0)
      {:okay, d} = SimDriver.write(d, 0x1008, 0xB2)
      {:okay, d} = SimDriver.write(d, 0x4000, 0xC0)
      assert SimDriver.peek(d, :a_ctrl) == 0x1234
      assert SimDriver.peek(d, :c_ctrl) == 0xC0
      assert {0x1234, :okay, d} = read!(d, 0x0000)
      assert {0xB0, :okay, d} = read!(d, 0x1000)
      assert {0xB2, :okay, d} = read!(d, 0x1008)
      assert {0xC0, :okay, _} = read!(d, 0x4000)
    end

    test "slave offsets: the slave sees the offset inside its range" do
      d = new_driver(ic_top(), []) |> SimDriver.poke(%{a_stat: 5})
      {:okay, d} = SimDriver.write(d, 0x4004, 0xFF)
      assert {0, :okay, d} = read!(d, 0x4004)
      d = SimDriver.poke(d, %{c_ev_set: 0b101}) |> SimDriver.idle(1)
      d = SimDriver.poke(d, %{c_ev_set: 0}) |> SimDriver.idle(1)
      assert {0b101, :okay, d} = read!(d, 0x4004)
      {:okay, d} = SimDriver.write(d, 0x4004, 0b001)
      assert {0b100, :okay, _} = read!(d, 0x4004)
    end

    test "unmapped addresses answer DECERR, reads return 0, nothing reaches a slave" do
      d = new_driver(ic_top(), delays: 0..1, seed: 9)
      {:okay, d} = SimDriver.write(d, 0x0000, 0x77)

      for addr <- [0x0100, 0x0FFC, 0x1010, 0x2000, 0x3FFC, 0x5000, 0xFFFC] do
        {:decerr, d2} = SimDriver.write(d, addr, 0xFFFF_FFFF)
        assert {0, :decerr, _} = read!(d2, addr)
        assert SimDriver.peek(d2, :a_ctrl) == 0x77
        assert SimDriver.peek(d2, :c_ctrl) == 0
      end

      # holes inside a slave's range are the slave's business (defregs: OKAY, 0)
      assert {0, :okay, d} = read!(d, 0x0040)
      assert {0x77, :okay, _} = read!(d, 0x0000)
    end

    test "unmapped: :slverr" do
      d = new_driver(ic_top(:slverr), [])
      {:slverr, d} = SimDriver.write(d, 0x2000, 1)
      assert {0, :slverr, _} = read!(d, 0x2000)
    end

    property "random traffic with random delays matches a model" do
      cells =
        [{0x0000, :rw}, {0x0004, :ro}, {0x1000, :rw}, {0x1004, :rw}, {0x100C, :rw}, {0x4000, :rw}] ++
          [{0x0040, :hole}, {0x2000, :unmapped}, {0x1010, :unmapped}, {0x8000, :unmapped}]

      check all(
              ops <-
                list_of(tuple({boolean(), member_of(cells), integer(0..0xFFFF_FFFF)}),
                  min_length: 10,
                  max_length: 50
                ),
              seed <- integer(),
              max_runs: 15
            ) do
        d = new_driver(ic_top(), delays: 0..4, seed: seed) |> SimDriver.poke(%{a_stat: 0x5A5A})

        Enum.reduce(ops, {%{}, d}, fn {wr?, {addr, kind}, data}, {m, d} ->
          cond do
            wr? ->
              {resp, d} = SimDriver.write(d, addr, data)
              assert resp == if(kind == :unmapped, do: :decerr, else: :okay)
              {if(kind == :rw, do: Map.put(m, addr, data), else: m), d}

            true ->
              {v, resp, d} = read!(d, addr)

              {want, wresp} =
                case kind do
                  :rw -> {Map.get(m, addr, if(addr == 0, do: 0xA, else: 0)), :okay}
                  :ro -> {0x5A5A, :okay}
                  :hole -> {0, :okay}
                  :unmapped -> {0, :decerr}
                end

              assert {v, resp} == {want, wresp}
              {m, d}
          end
        end)
      end
    end

    test "invalid ranges are rejected" do
      assert_raise ArgumentError, ~r/overlap/, fn ->
        AXIL.interconnect([{0, 0x100}, {0x80, 0x40}], addr_bits: 12)
      end

      assert_raise ArgumentError, ~r/multiple/, fn -> AXIL.interconnect([{0x40, 0x100}]) end

      assert_raise ArgumentError, ~r/outside/, fn ->
        AXIL.interconnect([{0x1000, 0x100}], addr_bits: 8)
      end
    end

    @tag :verilator
    @tag timeout: 300_000
    test "co-simulates against Verilator" do
      top = ic_top()
      d = new_driver(top, delays: 0..3, seed: 3)

      d =
        Enum.reduce(1..40, d, fn i, d ->
          addr = Enum.at([0, 4, 0x1000, 0x1004, 0x4000, 0x4004, 0x2000, 0x40], rem(i, 8))
          {_, d} = SimDriver.write(d, addr, i * 0x01010101)
          {_, _, d} = read!(d, addr)
          d
        end)

      Cosim.assert_equivalent(top, SimDriver.stimulus(d))
    end
  end
end
