defmodule ExHdlCores.ConvInterleaverTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdlCores.{ByteStream, ConvInterleaver}
  alias ExSdr.Comm.ConvInterleaver, as: Ref

  defp ref(bytes, i, m, mode) do
    c = Ref.new(branches: i, depth: m)
    bin = :binary.list_to_bin(bytes)

    out =
      if mode == :interleave,
        do: Ref.interleave(c, bin, native: false),
        else: Ref.deinterleave(c, bin, native: false)

    :binary.bin_to_list(out)
  end

  defp run(mod, bytes, opts) do
    r = ByteStream.run(mod, ByteStream.beats([:binary.list_to_bin(bytes)], last: false), opts)
    {ByteStream.bytes(r), r}
  end

  test "the model is ex_sdr's interleaver" do
    for {i, m, mode} <- [{3, 2, :deinterleave}, {4, 3, :interleave}, {12, 17, :deinterleave}] do
      bytes = for k <- 1..700, do: rem(k * 91, 256)
      assert ConvInterleaver.model(bytes, i, m, mode) == ref(bytes, i, m, mode)
    end
  end

  property "both directions equal ex_sdr for any length, random valid and ready" do
    check all(
            i <- integer(2..6),
            m <- integer(1..4),
            mode <- member_of([:interleave, :deinterleave]),
            bytes <- list_of(integer(0..255), min_length: 1, max_length: 120),
            vp <- integer(30..100),
            rp <- integer(30..100),
            seed <- integer(0..1000),
            max_runs: 25
          ) do
      mod = ConvInterleaver.build(branches: i, depth: m, mode: mode)
      {out, _} = run(mod, bytes, valid: vp, ready: rp, seed: seed)
      assert out == ref(bytes, i, m, mode)
    end
  end

  test "interleaver then deinterleaver is a pure delay of I * (I - 1) * M" do
    {i, m} = {4, 3}
    delay = i * (i - 1) * m
    bytes = for k <- 1..200, do: rem(k * 7 + 1, 255) + 1
    padded = bytes ++ List.duplicate(0, delay)
    {mid, _} = run(ConvInterleaver.build(branches: i, depth: m, mode: :interleave), padded, [])
    {out, _} = run(ConvInterleaver.build(branches: i, depth: m), mid, [])
    assert Enum.drop(out, delay) == bytes
  end

  test "DVB-T outer deinterleaver (I = 12, M = 17) with tlast every 204 bytes and the startup skipped" do
    mod = ConvInterleaver.build(branches: 12, depth: 17, packet: 204, skip: 2244)
    :rand.seed(:exsss, {5, 6, 7})
    bytes = for _ <- 1..(204 * 30), do: :rand.uniform(256) - 1
    r = ByteStream.run(mod, ByteStream.beats([:binary.list_to_bin(bytes)], last: false), valid: 80, ready: 60)
    expected = bytes |> ref(12, 17, :deinterleave) |> Enum.drop(2244)
    assert ByteStream.bytes(r) == expected

    lasts = r.out.m_axis |> Enum.map(& &1.tlast)
    assert lasts == for(k <- 1..length(expected), do: if(rem(k, 204) == 0, do: 1, else: 0))
  end

  test "one byte per clock" do
    mod = ConvInterleaver.build(branches: 12, depth: 17)
    bytes = for k <- 1..3000, do: rem(k, 256)
    {out, r} = run(mod, bytes, valid: 100, ready: 100, idle: 5)
    assert out == ref(bytes, 12, 17, :deinterleave)
    assert r.cycles <= 3000 + 1 + 5
  end

  # branch counter restarts at each tlast, the delay lines go on
  defp framed_ref(packets, i, m, mode) do
    fifos =
      for j <- 0..(i - 1), into: %{}, do: {j, List.duplicate(0, ConvInterleaver.branch_delay(i, m, mode, j))}

    {out, _} =
      Enum.flat_map_reduce(packets, fifos, fn p, fifos ->
        p
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Enum.map_reduce(fifos, fn {b, k}, fifos ->
          j = rem(k, i)

          case fifos[j] do
            [] -> {b, fifos}
            [o | rest] -> {o, Map.put(fifos, j, rest ++ [b])}
          end
        end)
      end)

    out
  end

  property "framing: tlast restarts the branch counter and is repeated on the output" do
    check all(
            i <- integer(2..5),
            m <- integer(1..3),
            pkts <- list_of(binary(min_length: 1, max_length: 25), min_length: 1, max_length: 6),
            seed <- integer(0..1000),
            max_runs: 20
          ) do
      mod = ConvInterleaver.build(branches: i, depth: m, framing: true)
      r = ByteStream.run(mod, ByteStream.beats(pkts), valid: 70, ready: 70, seed: seed)
      assert ByteStream.bytes(r) == framed_ref(pkts, i, m, :deinterleave)
      assert Enum.map(ByteStream.packets(r.out.m_axis), &byte_size(elem(&1, 0))) == Enum.map(pkts, &byte_size/1)
    end
  end

  @tag :verilator
  test "Verilator equals the BEAM simulator under random valid and ready" do
    for opts <- [
          [branches: 12, depth: 17, packet: 204, skip: 2244],
          [branches: 5, depth: 2, framing: true, mode: :interleave]
        ] do
      mod = ConvInterleaver.build(opts)
      :rand.seed(:exsss, {1, 2, 3})
      pkts = for _ <- 1..4, do: :rand.bytes(204 * 3)
      framed = opts[:framing] || false
      beats = ByteStream.beats(pkts, last: framed)
      a = ByteStream.run(mod, beats, valid: 75, ready: 65, seed: 9)
      b = ByteStream.run(mod, beats, valid: 75, ready: 65, seed: 9, backend: :verilator)
      assert a.out == b.out
      assert a.cycles == b.cycles
      if framed, do: :ok, else: assert(ByteStream.bytes(a) != [])
    end
  end
end
