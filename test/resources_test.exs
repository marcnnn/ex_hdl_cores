defmodule ExHdlCores.ResourcesTest do
  use ExUnit.Case, async: true

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdlCores.{AXIS, FIFO, Resources}

  defp util(m, family) do
    {:ok, u} = ExHdl.Synth.Yosys.utilization(SV.generate(m), m.name, family: family)
    u
  end

  @tag :verilator
  @tag timeout: 300_000
  test "every representative instance lints clean under -Wall" do
    for {label, m} <- Resources.instances() do
      dir =
        Path.join(System.tmp_dir!(), "ex_hdl_cores_lint_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      try do
        files =
          for {name, src} <- SV.generate(m) do
            path = Path.join(dir, name)
            File.write!(path, src)
            path
          end

        {out, status} =
          System.cmd("verilator", ["--lint-only", "-Wall", "--top-module", m.name | files],
            stderr_to_stdout: true
          )

        assert status == 0, "#{label}: #{out}"
      after
        File.rm_rf!(dir)
      end
    end
  end

  @tag :yosys
  @tag timeout: 600_000
  test "memories infer the intended resources" do
    assert %{bram18: 1, lutram: 0} = util(FIFO.sync_fifo(width: 32, depth: 512), "xc7")
    assert %{bram18: 1, lutram: 0} = util(FIFO.sync_fifo(width: 32, depth: 512), "xcup")
    assert %{bram18: 1, lutram: 0} = util(FIFO.async_fifo(width: 32, depth: 512), "xcup")

    assert %{bram18: 0, lutram: l} =
             util(FIFO.sync_fifo(width: 32, depth: 32, style: :distributed), "xcup")

    assert l > 0
    assert %{bram18: 3} = util(FIFO.axis(data: 64, depth: 512), "xcup")
    assert %{bram18: b} = util(FIFO.packet(data: 64, depth: 512), "xcup")
    assert b > 0

    assert %{uram: 1, bram18: 0} =
             util(FIFO.sync_fifo(width: 72, depth: 4096, style: :ultra), "xcup")
  end

  @tag :yosys
  @tag timeout: 600_000
  test "stream blocks and arbiters synthesise without memories or DSPs" do
    for m <- [AXIS.merge(3, data: 16), ExHdlCores.Arbiter.round_robin(6, hold: :packet)] do
      assert %{bram18: 0, uram: 0, dsp: 0, lutram: 0} = util(m, "xcup")
    end
  end
end
