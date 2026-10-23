defmodule ExHdlCores.ByteShiftTest do
  use ExUnit.Case, async: true

  alias ExHdl.RTL.Cosim
  alias ExHdlCores.{ByteShift, Tb}

  defp model(bytes, dir, keep?) do
    {nil,
     fn nil, i ->
       out = %{out: ByteShift.ref(i.data, i.off, bytes, dir)}

       out =
         if keep?,
           do: Map.put(out, :out_keep, kref(i.keep, i.off, bytes, dir)),
           else: out

       {nil, out}
     end}
  end

  defp kref(keep, off, bytes, :right),
    do: Bitwise.bsr(keep, off) |> Bitwise.band(Bitwise.bsl(1, bytes) - 1)

  defp kref(keep, off, bytes, :left),
    do: Bitwise.bsl(keep, off) |> Bitwise.band(Bitwise.bsl(1, bytes) - 1)

  test "reference" do
    assert ByteShift.ref(0x0102030405060708, 3, 8, :right) == 0x0102030405
    assert ByteShift.ref(0x0102030405060708, 3, 8, :left) == 0x0405060708000000
  end

  for bytes <- [1, 2, 6, 8, 64], dir <- [:right, :left], keep? <- [true, false] do
    test "#{bytes} bytes #{dir} keep #{keep?} matches ref/4" do
      {bytes, dir, keep?} = {unquote(bytes), unquote(dir), unquote(keep?)}
      mod = ByteShift.build(bytes: bytes, dir: dir, keep: keep?)
      stim = Tb.random_stimulus(mod, 100, bytes)
      assert :ok == Cosim.check_model(mod, stim, model(bytes, dir, keep?))
    end
  end

  @tag :verilator
  @tag timeout: 600_000
  test "8 byte right shift in Verilator" do
    mod = ByteShift.build(bytes: 8)
    stim = Tb.random_stimulus(mod, 100, 5)
    assert :ok == Cosim.check_model(mod, stim, model(8, :right, true), backend: :both)
  end
end
