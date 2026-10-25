defmodule ExHdlCores.EnergyDispersalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExHdlCores.{ByteStream, EnergyDispersal}
  alias ExSdr.DVBT.EnergyDispersal, as: Ref

  # a transport stream of `groups` groups of 8 packets, random payload
  defp ts(groups, seed) do
    :rand.seed(:exsss, {seed, 3, 4})

    for _ <- 1..(8 * groups), into: <<>> do
      <<0x47, :rand.bytes(187)::binary>>
    end
  end

  defp packets(bin), do: for(<<p::binary-size(188) <- bin>>, do: p)

  # junk packets whose first byte is not the inverted sync
  defp junk(n, seed) do
    :rand.seed(:exsss, {seed, 5, 6})

    for _ <- 1..n//1,
        do: <<Enum.random(Enum.to_list(0..255) -- [0xB8]), :rand.bytes(187)::binary>>
  end

  test "the model is ex_sdr's descrambler" do
    plain = ts(3, 1)
    scrambled = Ref.scramble(plain)
    assert :erlang.iolist_to_binary(EnergyDispersal.model(packets(scrambled))) == plain
  end

  test "descrambles a scrambled transport stream, the first sync inverted" do
    plain = ts(4, 2)
    scrambled = Ref.scramble(plain)
    assert binary_part(scrambled, 0, 1) == <<0xB8>>

    r =
      ByteStream.run(EnergyDispersal.build(), ByteStream.beats(packets(scrambled)),
        valid: 100,
        ready: 100,
        idle: 5
      )

    assert :binary.list_to_bin(ByteStream.bytes(r)) == plain

    assert Enum.map(ByteStream.packets(r.out.m_axis), &byte_size(elem(&1, 0))) ==
             List.duplicate(188, 32)

    assert r.cycles <= byte_size(plain) + 2 + 5
  end

  property "unaligned packets before the first 0xB8 are dropped, random valid and ready" do
    check all(
            lead <- integer(0..5),
            groups <- integer(1..3),
            cut <- integer(0..9),
            vp <- integer(30..100),
            rp <- integer(30..100),
            seed <- integer(0..1000),
            max_runs: 12
          ) do
      scrambled = Ref.scramble(ts(groups, seed))
      # start `cut` packets into the stream: the first 0xB8 is the next group start
      pkts = Enum.drop(packets(scrambled), min(cut, groups * 8 - 1))
      stream = junk(lead, seed) ++ pkts
      start = Enum.find_index(stream, &(:binary.first(&1) == 0xB8))

      expected =
        if start do
          aligned = stream |> Enum.drop(start) |> :erlang.iolist_to_binary()
          Ref.descramble_at(aligned, 0)
        else
          ""
        end

      r =
        ByteStream.run(EnergyDispersal.build(), ByteStream.beats(stream),
          valid: vp,
          ready: rp,
          seed: seed
        )

      assert :binary.list_to_bin(ByteStream.bytes(r)) == expected
    end
  end

  test "tuser is passed through and realign forgets the alignment" do
    plain = ts(2, 7)
    pkts = packets(Ref.scramble(plain))
    mod = EnergyDispersal.build(user: 2)
    beats = ByteStream.beats(pkts, extra: %{tuser: 2})
    r = ByteStream.run(mod, beats, fields: [:tdata, :tlast, :tuser], valid: 100, ready: 100)
    assert :binary.list_to_bin(ByteStream.bytes(r)) == plain
    assert Enum.all?(r.out.m_axis, &(&1.tuser == 2))

    # realign after the first packet of the second copy: packets are dropped up to the next 0xB8
    pre = fn sim, cycle ->
      ExHdl.RTL.Sim.poke(sim, %{realign: if(cycle == 17 * 188, do: 1, else: 0)})
    end

    stream = pkts ++ pkts
    beats = ByteStream.beats(stream, extra: %{tuser: 0})

    r =
      ByteStream.run(mod, beats,
        fields: [:tdata, :tlast, :tuser],
        valid: 100,
        ready: 100,
        pre: pre
      )

    out = :binary.list_to_bin(ByteStream.bytes(r))
    assert out == plain <> binary_part(plain, 0, 188) <> binary_part(plain, 8 * 188, 8 * 188)
  end

  @tag :verilator
  test "Verilator equals the BEAM simulator" do
    stream = junk(2, 3) ++ packets(Ref.scramble(ts(2, 3)))
    mod = EnergyDispersal.build()
    beats = ByteStream.beats(stream)
    a = ByteStream.run(mod, beats, valid: 70, ready: 60, seed: 4)
    b = ByteStream.run(mod, beats, valid: 70, ready: 60, seed: 4, backend: :verilator)
    assert a.out == b.out
    assert length(a.out.m_axis) == 2 * 8 * 188
  end
end
