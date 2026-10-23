defmodule ExHdlCores.Checksum do
  @moduledoc """
  Internet checksum (RFC 1071, ones' complement sum of 16-bit words) over
  words of `bytes` bytes per cycle, as an adder tree.

  Bytes pair up in network order: byte 0 of the packet is the high byte of
  word 0, so the bus must be an even number of bytes wide and only the
  last beat of a packet may be partial. A byte whose `keep` bit is low
  counts as zero, which also pads an odd last byte on the right as the RFC
  requires.

  `build/1` is a standalone accumulator with ports:

    * `data` (8 * bytes, byte 0 in the low bits, as AXI4-Stream `tdata`)
    * `keep` (bytes, with `keep: true`, the default): per-byte mask
    * `valid` - add this word
    * `clear` - restart from 0 before this word (without `valid`: just
      restart)
    * `sum` - the ones' complement sum of all words since the last clear,
      folded to 16 bits, one cycle after the word (two with `pipeline: 1`)
    * `csum` - `~sum`, the value for a checksum field; over a packet that
      includes a correct checksum field it is 0

  The sum is canonical: 0 only when every byte was zero, otherwise 0x0001
  to 0xFFFF, like `sum/1`.

  `window/3` and `fold/1` are the combinational pieces for other modules
  (a classifier summing a header window): `window(data, keep, bytes)` is
  the folded sum of the masked words of one bus word, and `fold(expr)`
  reduces any wider sum to 16 bits with end-around carry.

  Options of `build/1`: `bytes:` (even, 2 to 256, default 8), `keep:`,
  `pipeline:` (0 or 1: a register between the adder tree and the
  accumulator for timing, adds a cycle of latency).

  `sum/1` and `csum/1` are the reference on binaries.
  """
  use ExHdl.RTL
  import Bitwise, only: [band: 2, bsr: 2]

  @doc "Reference: folded ones' complement sum of a binary (odd length padded with a zero byte)."
  def sum(bin) do
    bin = if rem(byte_size(bin), 2) == 1, do: bin <> <<0>>, else: bin
    total = for <<w::16 <- bin>>, reduce: 0, do: (a -> a + w)
    fold_int(total)
  end

  @doc "Reference: `~sum/1`, the checksum field value."
  def csum(bin), do: Bitwise.bxor(sum(bin), 0xFFFF)

  @doc false
  def fold_int(x) when x > 0xFFFF, do: fold_int(band(x, 0xFFFF) + bsr(x, 16))
  def fold_int(x), do: x

  @doc """
  Folds an unsigned sum expression to 16 bits with end-around carry. Valid
  for sums below 2^32 (up to 65535 words).
  """
  def fold(x) do
    {_, w} = x.type

    cond do
      w <= 16 -> if(w == 16, do: x, else: rtl(do: zext(x, 16)))
      w == 17 -> rtl(do: add_wrap(x[0..15], x[16]))
      true -> fold(rtl(do: x[0..15] + x[16..(w - 1)]))
    end
  end

  @doc """
  Folded ones' complement sum of the 16-bit words of `data` (`bytes`
  bytes, byte 0 in the low bits) with the bytes selected by `keep`
  (`nil`: all). A combinational adder tree.
  """
  def window(data, keep, bytes) when rem(bytes, 2) == 0 and bytes >= 2 do
    words =
      for k <- 0..(div(bytes, 2) - 1) do
        hi = lane(data, keep, 2 * k)
        lo = lane(data, keep, 2 * k + 1)
        rtl(do: cat([hi, lo]))
      end

    fold(tree(words))
  end

  defp lane(data, nil, i), do: rtl(do: data[(8 * i)..(8 * i + 7)])

  defp lane(data, keep, i),
    do: rtl(do: data[(8 * i)..(8 * i + 7)] &&& rep(keep[i], 8))

  defp tree([x]), do: x

  defp tree(list) do
    list
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [a, b] -> rtl(do: a + b)
      [a] -> a
    end)
    |> tree()
  end

  @doc "Accumulator module; see the moduledoc."
  def build(opts \\ []) do
    bytes = Keyword.get(opts, :bytes, 8)
    keep? = Keyword.get(opts, :keep, true)
    pipe = Keyword.get(opts, :pipeline, 0)

    unless rem(bytes, 2) == 0 and bytes in 2..256 and pipe in [0, 1],
      do: raise(ArgumentError, "checksum: bytes must be even (2..256), pipeline 0 or 1")

    module "inet_csum_b#{bytes}#{if keep?, do: "k", else: ""}_p#{pipe}" do
      data = input(:data, 8 * bytes)
      keep = if keep?, do: input(:keep, bytes)
      valid = input(:valid, 1)
      clear = input(:clear, 1)
      sum = output(:sum, 16)
      csum = output(:csum, 16)
      acc = reg(:acc, 16)

      lanes = wire(:lanes, window(data, keep, bytes))

      {l, v, c} =
        if pipe == 1 do
          lr = reg(:lanes_r, 16)
          vr = reg(:valid_r, 1)
          cr = reg(:clear_r, 1)

          sync do
            lr <~ lanes
            vr <~ valid
            cr <~ clear
          end

          {lr, vr, cr}
        else
          {lanes, valid, clear}
        end

      base = wire(:base, mux(c, const(0, 16), acc))

      sync do
        if v do
          acc <~ fold(base + l)
        else
          if c, do: acc <~ 0
        end
      end

      sum <~ acc
      csum <~ bxor(acc, 0xFFFF)
    end
  end
end
