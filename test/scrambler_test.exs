defmodule ExHdlCores.ScramblerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdl.RTL.Cosim
  alias ExHdlCores.{Scrambler, Tb}

  defp model(poly, width, mode, seed) do
    {seed,
     fn st, %{data: d, en: en} = i ->
       {ns, out} = Scrambler.step(st, d, width, poly, mode)

       cond do
         Map.get(i, :rst_n, 1) == 0 -> {seed, %{out: nil}}
         en == 1 -> {ns, %{out: out}}
         true -> {st, %{out: out}}
       end
     end}
  end

  describe "reference" do
    test "PRBS7 has period 127" do
      bits =
        Enum.map_reduce(1..254, 0x7F, fn _, s ->
          {s, o} = Scrambler.step(s, 0, 1, [7, 6], :prbs)
          {o, s}
        end)
        |> elem(0)

      {a, b} = Enum.split(bits, 127)
      assert a == b
      assert Enum.sum(a) == 64
      refute Enum.take(a, 63) == Enum.slice(a, 63, 63)
    end

    property "descramble undoes scramble; the descrambler syncs after n bits" do
      check all(
              words <- list_of(integer(0..0xFFFF_FFFF), min_length: 3, max_length: 10),
              s0 <- integer(0..(2 ** 58 - 1)),
              d0 <- integer(0..(2 ** 58 - 1))
            ) do
        poly = [58, 39]

        {scr, _} =
          Enum.map_reduce(words, s0, fn w, s ->
            {s, o} = Scrambler.step(s, w, 32, poly, :scramble)
            {o, s}
          end)

        {plain, _} =
          Enum.map_reduce(scr, d0, fn w, s ->
            {s, o} = Scrambler.step(s, w, 32, poly, :descramble)
            {o, s}
          end)

        assert Enum.drop(plain, 2) == Enum.drop(words, 2)
      end
    end

    test "matrix of a linear step matches the step" do
      m = Scrambler.masks([7, 4], 8)
      parity = fn x -> x |> Integer.digits(2) |> Enum.sum() |> rem(2) end

      for s <- [0, 1, 0x55, 0x7F], d <- [0, 0xA5, 0xFF] do
        {ns, o} = Scrambler.step(s, d, 8, [7, 4])

        bit = fn ms, md, k ->
          Bitwise.bxor(
            parity.(Bitwise.band(s, Enum.at(ms, k))),
            parity.(Bitwise.band(d, Enum.at(md, k)))
          )
        end

        assert ns ==
                 Enum.reduce(0..6, 0, &Bitwise.bor(&2, Bitwise.bsl(bit.(m.ns_s, m.ns_d, &1), &1)))

        assert o ==
                 Enum.reduce(0..7, 0, &Bitwise.bor(&2, Bitwise.bsl(bit.(m.o_s, m.o_d, &1), &1)))
      end
    end
  end

  describe "hardware" do
    for {poly, width, mode} <- [
          {[58, 39], 64, :scramble},
          {[58, 39], 64, :descramble},
          {[7, 6], 8, :prbs},
          {[31, 28], 32, :prbs},
          {[7, 4], 1, :scramble}
        ] do
      test "x#{Enum.join(poly, "+x")} #{width} bit #{mode} matches step/5" do
        {poly, width, mode} = {unquote(poly), unquote(width), unquote(mode)}
        mod = Scrambler.build(poly: poly, width: width, mode: mode)
        seed = unquote(if mode == :descramble, do: 0, else: 2 ** Enum.max(poly) - 1)
        stim = Tb.random_stimulus(mod, 200, width, bias: %{en: 80})
        assert :ok == Cosim.check_model(mod, stim, model(poly, width, mode, seed))
      end
    end

    @tag :verilator
    @tag timeout: 600_000
    test "64 bit scrambler in Verilator" do
      mod = Scrambler.build(poly: [58, 39])
      stim = Tb.random_stimulus(mod, 100, 3)
      model = model([58, 39], 64, :scramble, 2 ** 58 - 1)
      assert :ok == Cosim.check_model(mod, stim, model, backend: :both)
    end
  end
end
