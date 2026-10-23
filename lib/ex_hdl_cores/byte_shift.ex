defmodule ExHdlCores.ByteShift do
  @moduledoc """
  Byte-lane barrel shifter by a runtime offset, byte 0 in the low bits as
  AXI4-Stream `tdata`.

  `:right` moves byte `i + off` to lane `i` (drops `off` leading bytes, as
  when a payload starts at `off` in the first beat), `:left` moves byte `i`
  to lane `i + off`. Vacated lanes are 0, and their `keep` bits too.

  `build/1` is combinational with ports `data` (8 * bytes), `keep` (bytes,
  with `keep: true`, the default), `off` (clog2 of bytes bits), `out` and
  `out_keep`. Options: `bytes:` (1 to 256, default 8), `dir:` (`:right`,
  the default, or `:left`), `keep:`. An offset of `bytes` or more (when
  `bytes` is not a power of two) gives 0.

  `shift/4` is the expression for other modules: one 2:1 mux stage per
  offset bit. `ref/4` is the reference on integers.
  """
  use ExHdl.RTL
  alias Bitwise, as: B

  @doc "Reference: `data` (`bytes` bytes) shifted by `off` bytes in `dir`."
  def ref(data, off, bytes, dir) do
    w = 8 * bytes
    v = if dir == :right, do: B.bsr(data, 8 * off), else: B.bsl(data, 8 * off)
    B.band(v, B.bsl(1, w) - 1)
  end

  @doc "Offset width for a bus of `bytes` bytes."
  def off_bits(bytes) when bytes <= 1, do: 1
  def off_bits(bytes), do: ceil(:math.log2(bytes))

  @doc """
  `x` (`lanes * lane` bits) shifted by `off` lanes of `lane` bits in
  `dir`: one mux stage per bit of `off`, bit 0 first.
  """
  def shift(x, off, dir, lane \\ 8) do
    {_, w} = x.type
    {_, ob} = off.type

    Enum.reduce(0..(ob - 1), x, fn k, acc ->
      s = lane * B.bsl(1, k)

      shifted =
        cond do
          s >= w -> rtl(do: const(0, w))
          dir == :right -> rtl(do: cat([const(0, s), acc[s..(w - 1)]]))
          true -> rtl(do: cat([acc[0..(w - 1 - s)], const(0, s)]))
        end

      rtl(do: mux(off[k], shifted, acc))
    end)
  end

  @doc "Shifter module; see the moduledoc."
  def build(opts \\ []) do
    bytes = Keyword.get(opts, :bytes, 8)
    dir = Keyword.get(opts, :dir, :right)
    keep? = Keyword.get(opts, :keep, true)

    unless bytes in 1..256 and dir in [:right, :left],
      do: raise(ArgumentError, "byte_shift: bytes 1..256, dir :right or :left")

    module "byte_shift_#{dir}_b#{bytes}#{if keep?, do: "k", else: ""}" do
      data = input(:data, 8 * bytes)
      off = input(:off, off_bits(bytes))
      out = output(:out, 8 * bytes)
      out <~ shift(data, off, dir)

      case keep? do
        true ->
          keep = input(:keep, bytes)
          out_keep = output(:out_keep, bytes)
          out_keep <~ shift(keep, off, dir, 1)

        false ->
          :ok
      end
    end
  end
end
