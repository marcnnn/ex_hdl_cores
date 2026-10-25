defmodule ExHdlCores.ViterbiTest do
  use ExUnit.Case, async: true

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExHdl.RTL.Cosim
  alias ExHdlCores.{Tb, Viterbi}
  alias ExHdlCores.ViterbiTb, as: VT

  @rates Viterbi.dvbt_rates()

  # code bits of a random message at a DVB-T rate, flipped at `p` per mille
  defp stream(rate_index, len, p, seed) do
    :rand.seed(:exsss, {seed, 5, 6})
    rate = Enum.at(@rates, rate_index)
    %{bits: len |> VT.info() |> VT.encode(rate) |> VT.noise(p), rate: rate_index}
  end

  # decoded streams of the module and of ex_sdr for the same streams
  defp check(mod, streams, depth, opts \\ []) do
    expected =
      Enum.map(streams, &VT.expected(&1.bits, &1.rate, depth, Keyword.get(opts, :ex, [])))

    n = expected |> Enum.map(&length/1) |> Enum.sum()
    {got, r} = VT.run(mod, streams, [expect: n] ++ Keyword.delete(opts, :ex))
    assert length(got) == length(expected)

    for {g, e} <- Enum.zip(got, expected) do
      assert length(g) == length(e)
      assert g == e
    end

    r
  end

  describe "configuration" do
    test "metric width for the DVB-T code" do
      cfg = Viterbi.config([])
      assert %{w: 6, init: 13, ns: 64, ring: 384, bmw: 2} = cfg
      assert %{w: 9, init: 85} = Viterbi.config(soft: 3)
    end

    test "bad parameters are rejected" do
      assert_raise ArgumentError, fn -> Viterbi.build(puncture: [[[1, 0], [1, 0, 1]]]) end
      assert_raise ArgumentError, fn -> Viterbi.build(puncture: [[[1, 0], [0, 0]]]) end
      assert_raise ArgumentError, fn -> Viterbi.build(polys: [0o171]) end
      assert_raise ArgumentError, fn -> Viterbi.build(soft: 9) end
    end

    test "port list" do
      names = fn m -> m.ports |> Enum.map(& &1.name) |> Enum.sort() end
      assert :s_axis_tuser in names.(Viterbi.dvbt())
      refute :s_axis_tuser in names.(Viterbi.build())
    end
  end

  describe "reference model" do
    test "same bits as ex_sdr's streaming decoder at every rate, depth and start" do
      for ri <- 0..4, depth <- [3, 8, 20], start <- [:zero, :unknown], len <- [1, 5, 40, 61] do
        s = stream(ri, len, 80, ri * 100 + len)
        rows = Enum.at(Viterbi.dvbt_rates(), ri) |> Viterbi.dvbt_pattern()

        got = Viterbi.ref(s.bits, depth: depth, start: start, puncture: [rows])
        exp = VT.ex_sdr(VT.code(rows), s.bits, depth: depth, start: start)
        assert got == exp, "rate #{ri} depth #{depth} start #{start} len #{len}"
      end
    end
  end

  describe "BEAM simulator against ex_sdr" do
    test "every DVB-T rate, every length around the windows, random handshakes" do
      mod = Viterbi.dvbt(depth: 8)

      for ri <- 0..4, len <- [1, 2, 3, 5, 7, 8, 9, 15, 16, 17, 23, 24, 25, 31, 33, 50] do
        s = stream(ri, len, 30, ri * 1000 + len)
        # an incomplete last puncturing period
        s = %{s | bits: Enum.take(s.bits, max(1, length(s.bits) - rem(len, 3)))}
        check(mod, [s], 8, valid: 60, ready: 50, seed: len)
      end
    end

    test "default depth 128, long noisy streams, every rate" do
      mod = Viterbi.dvbt()

      for ri <- 0..4, len <- [127, 128, 129, 256, 300, 700] do
        check(mod, [stream(ri, len, 60, len + ri)], 128, valid: 90, ready: 90, seed: len)
      end
    end

    test "back-to-back streams with different rates" do
      mod = Viterbi.dvbt(depth: 16)
      lens = [40, 3, 200, 16, 33, 90, 5, 130]
      streams = for {len, i} <- Enum.with_index(lens), do: stream(rem(i * 3, 5), len, 50, i)
      check(mod, streams, 16, valid: 80, ready: 60, seed: 4)
    end

    test "the output stalls for long periods" do
      mod = Viterbi.dvbt(depth: 8)
      streams = for {ri, len} <- [{2, 100}, {4, 60}, {0, 45}], do: stream(ri, len, 40, len)
      check(mod, streams, 8, valid: 100, ready: 4, seed: 9)
    end

    test "the input is sparse" do
      mod = Viterbi.dvbt(depth: 8)
      check(mod, [stream(3, 70, 40, 3), stream(1, 20, 40, 4)], 8, valid: 8, ready: 100, seed: 2)
    end

    test "pure noise decodes like ex_sdr" do
      mod = Viterbi.dvbt(depth: 8)
      :rand.seed(:exsss, {7, 7, 7})
      s = %{bits: VT.info(150), rate: 2}
      check(mod, [s], 8)
    end

    test "start: :unknown" do
      mod = Viterbi.build(depth: 8, start: :unknown, puncture: [Viterbi.dvbt_pattern({1, 2})])
      s = stream(0, 60, 100, 1)
      check(mod, [%{s | rate: 0}], 8, ex: [start: :unknown])
    end

    test "one pattern: no tuser, no puncturing, odd number of bits" do
      mod = Viterbi.build(depth: 8)
      s = stream(0, 37, 50, 5)
      check(mod, [%{s | bits: tl(s.bits)}], 8)
    end

    test "throughput at rate 7/8 and 1/2 with an always ready sink" do
      mod = Viterbi.dvbt()

      for {ri, max_clk_per_bit} <- [{4, 2.4}, {0, 2.9}] do
        s = stream(ri, 2000, 20, 11)
        r = check(mod, [s], 128, valid: 100, ready: 100)
        assert r.cycles / 2000 < max_clk_per_bit
      end
    end

    test "other constraint lengths, generators and a three output code" do
      codes = [
        {3, [0o7, 0o5], [[1, 1], [1, 0]]},
        {5, [0o23, 0o35], [[1], [1]]},
        {4, [0o17, 0o15, 0o13], [[1, 1], [1, 0], [0, 1]]},
        {9, [0o561, 0o753], [[1, 0, 1], [1, 1, 0]]}
      ]

      for {k, polys, rows} <- codes do
        mod = Viterbi.build(k: k, polys: polys, puncture: [rows], depth: 12)
        code = VT.code(rows, k: k, polys: polys)
        :rand.seed(:exsss, {k, 1, 1})
        info = VT.info(90)
        bits = info |> then(&ExSdr.Comm.Convolutional.encode(code, &1)) |> VT.noise(40)
        exp = VT.ex_sdr(code, bits, depth: 12)
        {[got], _} = VT.run(mod, [%{bits: bits}], expect: length(exp), valid: 70, ready: 70)
        assert got == exp, "K = #{k}"
      end
    end

    test "soft decisions against the reference model" do
      for q <- [2, 3] do
        pats = Enum.map(Enum.take(@rates, 3), &Viterbi.dvbt_pattern/1)
        mod = Viterbi.build(depth: 10, soft: q, puncture: pats)
        maxv = Bitwise.bsl(1, q) - 1
        :rand.seed(:exsss, {q, 2, 2})

        for ri <- 0..2, len <- [7, 30, 64] do
          rate = Enum.at(@rates, ri)
          hard = len |> VT.info() |> VT.encode(rate)
          # a sure value with some noise: the soft value of the sent bit
          soft =
            for b <- hard do
              v = :rand.uniform(maxv + 1) - 1

              if b == 1,
                do: max(v, maxv - :rand.uniform(maxv + 1) + 1),
                else: min(v, :rand.uniform(maxv + 1) - 1)
            end

          exp = Viterbi.ref(soft, depth: 10, soft: q, puncture: pats, pattern: Enum.at(pats, ri))

          {[got], _} =
            VT.run(mod, [%{bits: soft, rate: ri}], expect: length(exp), valid: 75, ready: 75)

          assert got == exp, "soft #{q} rate #{ri} len #{len}"
        end
      end
    end

    test "soft decisions with one bit are the hard decisions" do
      s = stream(2, 50, 50, 8)
      pat = Viterbi.dvbt_pattern({3, 4})

      assert Viterbi.ref(s.bits, depth: 8, soft: 1, puncture: [pat]) ==
               Viterbi.ref(s.bits, depth: 8, puncture: [pat])
    end
  end

  describe "Verilator" do
    @describetag :verilator
    @describetag timeout: 900_000

    test "decoded bits of every rate equal ex_sdr's, with random handshakes" do
      mod = Viterbi.dvbt(depth: 8)

      streams =
        for {ri, len} <- [{0, 30}, {1, 45}, {2, 17}, {3, 60}, {4, 29}, {2, 8}],
            do: stream(ri, len, 50, len)

      check(mod, streams, 8, backend: :verilator, valid: 70, ready: 60, seed: 3)
    end

    test "default depth in Verilator" do
      check(Viterbi.dvbt(), [stream(2, 400, 50, 1), stream(4, 300, 50, 2)], 128,
        backend: :verilator,
        valid: 90,
        ready: 90
      )
    end

    test "BEAM simulator and Verilator agree on random inputs, every output every cycle" do
      mod = Viterbi.dvbt(depth: 6)

      for seed <- 1..2 do
        stim =
          mod
          |> Tb.random_stimulus(900, seed,
            bias: %{s_axis_tvalid: 85, s_axis_tlast: 4, m_axis_tready: 70}
          )
          |> Enum.map(&Map.update!(&1, :s_axis_tuser, fn u -> rem(u, 5) end))

        Cosim.assert_equivalent(mod, stim)
      end
    end

    test "the generated SystemVerilog lints clean under -Wall" do
      for mod <- [Viterbi.dvbt(), Viterbi.build(k: 4, polys: [0o17, 0o15, 0o13], soft: 3)] do
        dir = Path.join(System.tmp_dir!(), "viterbi_lint_#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)

        try do
          files =
            for {name, src} <- SV.generate(mod) do
              path = Path.join(dir, name)
              File.write!(path, src)
              path
            end

          {out, status} =
            System.cmd("verilator", ["--lint-only", "-Wall", "--top-module", mod.name | files],
              stderr_to_stdout: true
            )

          assert status == 0, out
        after
          File.rm_rf!(dir)
        end
      end
    end
  end

  describe "Yosys" do
    @describetag :yosys
    @describetag timeout: 600_000

    test "the DVB-T decoder is one block RAM and about a thousand LUTs" do
      m = Viterbi.dvbt()
      {:ok, u} = ExHdl.Synth.Yosys.utilization(SV.generate(m), m.name, family: "xc7")
      assert u.bram36 == 1.0
      assert u.dsp == 0
      assert u.lut < 2000
      assert u.ff < 800
    end
  end
end
