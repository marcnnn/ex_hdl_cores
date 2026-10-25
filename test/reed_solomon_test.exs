defmodule ExHdlCores.ReedSolomonTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExHdlCores.{ByteStream, ReedSolomon, RsCases}
  alias ExSdr.Comm.GF
  alias ExSdr.DVBT.ReedSolomon, as: Dvb

  @codes [
    # name, options (GF(16), fcr 1)
    small: [m: 4, field_poly: 0x13, n: 15, k: 9, fcr: 1, prim: 1],
    # GF(32), first root 3, root step 2, shortened
    gf32: [m: 5, field_poly: 0x25, n: 31, k: 23, fcr: 3, prim: 2, shortening: 5],
    # CCSDS style: fcr 112, prim 11, shortened
    ccsds: [m: 8, field_poly: 0x187, n: 255, k: 239, fcr: 112, prim: 11, shortening: 100]
  ]

  defp beats(words), do: ByteStream.beats(Enum.map(words, &:binary.list_to_bin/1), last: false)

  # runs the words through the hardware; returns [{message, failed?, corrected?}] and the stat sums
  defp hw(mod, code, words, opts \\ []) do
    msg = ExSdr.Comm.ReedSolomon.message_length(code)

    r =
      ByteStream.run(
        mod,
        beats(words),
        [
          fields: [:tdata],
          out_fields: [:tdata, :tlast, :tuser],
          watch: [:stat_valid, :stat_failed, :stat_errors],
          idle: 600
        ] ++
          opts
      )

    cws =
      r.out.m_axis
      |> Enum.chunk_every(msg)
      |> Enum.map(fn beats ->
        assert length(beats) == msg
        assert Enum.map(beats, & &1.tlast) == List.duplicate(0, msg - 1) ++ [1]
        assert beats |> Enum.map(& &1.tuser) |> Enum.uniq() |> length() == 1
        u = hd(beats).tuser
        {Enum.map(beats, & &1.tdata), (u &&& 1) == 1, (u >>> 1 &&& 1) == 1}
      end)

    {cws, r}
  end

  defp check_words(opts, count, seed, run_opts) do
    code = RsCases.code(opts)
    mod = ReedSolomon.build(opts)
    words = RsCases.batch(code, count, seed)
    {got, r} = hw(mod, code, words, run_opts)
    expected = Enum.map(words, &RsCases.expect(code, &1))
    assert length(got) == count

    for {{msg, failed, corrected}, {emsg, efailed, errors}, i} <-
          Enum.zip([got, expected, 0..count]) do
      assert {i, msg, failed, corrected} == {i, emsg, efailed, errors > 0}
    end

    assert r.watched.stat_valid == count
    assert r.watched.stat_failed == Enum.count(expected, &elem(&1, 1))
    assert r.watched.stat_errors == expected |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    r
  end

  for {name, opts} <- @codes do
    test "#{name}: clean, correctable, uncorrectable and garbage words equal ex_sdr" do
      check_words(unquote(opts), 18, 1, valid: 100, ready: 100)
    end

    test "#{name}: random valid and ready" do
      check_words(unquote(opts), 12, 2, valid: 55, ready: 40, seed: 3)
    end
  end

  test "all error counts up to 2t + 3 on the small code, errors anywhere including parity" do
    opts = @codes[:small]
    code = RsCases.code(opts)
    :rand.seed(:exsss, {4, 5, 6})
    words = for nerr <- 0..9, _ <- 1..4, do: RsCases.word(code, nerr)
    {got, _} = hw(ReedSolomon.build(opts), code, words)

    for {{msg, failed, corrected}, w} <- Enum.zip(got, words) do
      {emsg, efailed, errors} = RsCases.expect(code, w)
      assert {msg, failed, corrected} == {emsg, efailed, errors > 0}
    end
  end

  test "two slots stall the input instead of overwriting, output backpressure" do
    check_words(@codes[:small] ++ [slots: 2], 20, 5, valid: 100, ready: 20, seed: 1)
  end

  describe "DVB-T RS(204, 188)" do
    test "words against ex_sdr's decode, with the corrected and failed counts of decode_all" do
      code =
        RsCases.code(
          @codes[:ccsds]
          |> Keyword.merge(field_poly: 0x11D, fcr: 0, prim: 1, shortening: 51)
        )

      :rand.seed(:exsss, {7, 8, 9})
      words = RsCases.batch(code, 36, 7)
      {got, r} = hw(ReedSolomon.dvbt(), code, words, valid: 100, ready: 100)

      {packets, corrected, failed} =
        words |> Enum.map(&:binary.list_to_bin/1) |> IO.iodata_to_binary() |> Dvb.decode_all()

      assert :binary.list_to_bin(Enum.flat_map(got, &elem(&1, 0))) == packets
      assert r.watched.stat_errors == corrected
      assert r.watched.stat_failed == failed
      assert r.watched.stat_valid == 36
    end

    test "sustains one byte per clock: back-to-back codewords, no gap on the input" do
      code =
        RsCases.code(
          @codes[:ccsds]
          |> Keyword.merge(field_poly: 0x11D, fcr: 0, prim: 1, shortening: 51)
        )

      words = RsCases.batch(code, 12, 11)
      {got, r} = hw(ReedSolomon.dvbt(), code, words, valid: 100, ready: 100)
      assert length(got) == 12
      assert r.consumed.s_axis == 12 * 204
      # the last byte goes in at cycle 12 * 204 at the earliest; the last word leaves
      # 70 (Berlekamp-Massey) + 204 (Chien) + 6 + 188 (output) cycles later. One lost
      # input cycle per codeword would add 12 cycles.
      assert r.cycles <= 12 * 204 + 470 + 40
    end
  end

  # Gauss-Jordan over GF(256): x with a * x = b (a square, lists of rows)
  defp solve(f, a, b) do
    rows = Enum.zip_with(a, b, &(&1 ++ [&2]))
    n = length(a)

    rows =
      Enum.reduce(0..(n - 1), rows, fn col, rows ->
        {pivot, rest} =
          Enum.split_with(Enum.drop(rows, col), &(Enum.at(&1, col) != 0))
          |> then(fn {p, r} -> {hd(p), tl(p) ++ r} end)

        inv = GF.divide(f, 1, Enum.at(pivot, col))
        pivot = Enum.map(pivot, &GF.mul(f, &1, inv))
        top = Enum.take(rows, col)

        elim = fn row ->
          c = Enum.at(row, col)
          Enum.zip_with(row, pivot, &Bitwise.bxor(&1, GF.mul(f, c, &2)))
        end

        Enum.map(top, elim) ++ [pivot] ++ Enum.map(rest, elim)
      end)

    Enum.map(rows, &List.last/1)
  end

  test "syndromes whose Berlekamp-Massey length exceeds t with locator degree 0: data passes, flagged failed (documented difference)" do
    # S_1 and S_8 only: L = 9 but the locator is 1, which ex_sdr reports as decoded with no corrections
    s = [0, 223, 0, 0, 0, 0, 0, 0, 60, 0, 0, 0, 0, 0, 0, 0]
    f = GF.new(8, 0x11D)
    # errors at the last 16 symbols (powers 0..15): S_i = sum e_p alpha^(p i)
    a = for i <- 0..15, do: for(p <- 0..15, do: GF.pow(f, p * i))
    e = solve(f, a, s)
    code = RsCases.code(m: 8, field_poly: 0x11D, n: 255, k: 239, shortening: 51)
    :rand.seed(:exsss, {1, 1, 1})
    cw = RsCases.word(code, 0)
    errors = List.duplicate(0, 188) ++ Enum.reverse(e)
    word = Enum.zip_with(cw, errors, &Bitwise.bxor/2)
    assert {:ok, _, 0} = ExSdr.Comm.ReedSolomon.decode(code, word)
    {[{msg, failed, corrected}], _} = hw(ReedSolomon.dvbt(), code, [word])
    assert msg == Enum.take(word, 188)
    assert failed
    refute corrected
  end

  @tag :verilator
  test "Verilator equals the BEAM simulator" do
    opts = @codes[:small]
    code = RsCases.code(opts)
    mod = ReedSolomon.build(opts)
    words = RsCases.batch(code, 14, 21)

    run = [
      valid: 80,
      ready: 60,
      seed: 5,
      fields: [:tdata],
      out_fields: [:tdata, :tlast, :tuser],
      idle: 300
    ]

    a = ByteStream.run(mod, beats(words), run)
    b = ByteStream.run(mod, beats(words), run ++ [backend: :verilator])
    assert a.out == b.out
    assert a.cycles == b.cycles
    assert length(a.out.m_axis) == 14 * 9
  end
end
