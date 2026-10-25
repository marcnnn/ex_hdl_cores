defmodule ExHdlCores.CommaAligner do
  @moduledoc """
  Word alignment on a comma for 8b/10b links (1000BASE-X, K28.5): the
  transceiver delivers the serial stream cut into `width`-bit chunks at an
  arbitrary bit offset, the aligner finds the comma and shifts the stream
  so that every output word is one code group.

  Replaces the alignment half of ex_net's `ExNet.RTL.PCS1000X.build_rx/0`
  (`p1`, `p2`, `shift_r`, `algn`); there it is followed by the 8b10b core.

  Ports of `build/1`:

    * `code` (`width`, default 10) - input chunk, bit `width - 1` is the
      earliest bit on the wire
    * `lock` - freeze the offset (tie it to the receiver's `sync`): while
      low every comma found loads `shift`, while high `shift` is kept, so
      a slipped stream is re-aligned only after the receiver dropped
      `lock`
    * `aligned` (`width`) - the aligned group, registered
    * `shift` (clog2 of `width`) - the chosen bit offset
    * `found` - a comma starts at some offset in the window of the
      previous and the current chunk (combinational)

  A comma is a `comma_len` bit pattern (7 by default) from `commas:`
  (default `0b0011111` and `0b1100000`, the comma of K28.1/5/7 in either
  disparity). The 2 * `width` bit window of previous and current chunk is
  searched at each of the `width` start offsets, the lowest offset wins.
  A second window, one chunk older, is shifted by `shift` so that the
  group that starts at the comma is not lost. Latency: the group whose
  first bit is bit `b` of chunk `j` (needs chunks `j` and `j + 1` if
  `b > 0`) is on `aligned` in cycle `j + 2`. Throughput one group per
  cycle.

  `ref/2` is the reference on integers: chunks in, `{aligned, shift}` per
  cycle out.
  """
  use ExHdl.RTL

  @doc """
  Reference model, same behaviour as the module: `chunks` is a list of
  `{code, lock?}`; returns the `{aligned, shift}` seen in each cycle (the
  outputs are registers, so a chunk affects the output two cycles later).
  Options as `build/1`.
  """
  def ref(chunks, opts \\ []) do
    {width, commas, len} = cfg(opts)
    mask = Bitwise.bsl(1, width) - 1

    {rev, _} =
      Enum.reduce(chunks, {[], {0, 0, 0, 0}}, fn {code, lock}, {acc, {p1, p2, shift, algn}} ->
        w = Bitwise.bor(Bitwise.bsl(p1, width), code)

        cand =
          Enum.reduce((width - 1)..0//-1, shift, fn k, a ->
            pat = Bitwise.band(Bitwise.bsr(w, 2 * width - len - k), Bitwise.bsl(1, len) - 1)
            if pat in commas, do: k, else: a
          end)

        ext = Bitwise.bor(Bitwise.bsl(p2, width), p1)
        pick = Bitwise.band(Bitwise.bsr(ext, width - shift), mask)
        shift2 = if lock == 0, do: cand, else: shift
        {[{algn, shift} | acc], {code, p1, shift2, pick}}
      end)

    Enum.reverse(rev)
  end

  defp cfg(opts) do
    width = Keyword.get(opts, :width, 10)
    len = Keyword.get(opts, :comma_len, 7)
    commas = Keyword.get(opts, :commas, [0b0011111, 0b1100000])

    if len > width or Enum.any?(commas, &(&1 >= Bitwise.bsl(1, len))),
      do: raise(ArgumentError, "commas must fit in comma_len bits, comma_len <= width")

    {width, commas, len}
  end

  @doc """
  The aligner module `comma_align_w<width>_<commas>`; options `width:`,
  `commas:`, `comma_len:`, `name:` (see the moduledoc).
  """
  def build(opts \\ []) do
    {width, commas, len} = cfg(opts)
    sw = max(ceil(:math.log2(width)), 1)

    name =
      Keyword.get_lazy(opts, :name, fn ->
        "comma_align_w#{width}_l#{len}_" <> Enum.map_join(commas, "_", &Integer.to_string(&1, 16))
      end)

    module name do
      code = input(:code, width)
      lock = input(:lock, 1)
      aligned = output(:aligned, width)
      shift_o = output(:shift, sw)
      found = output(:found, 1)
      p1 = reg(:p1, width, reset: 0)
      p2 = reg(:p2, width, reset: 0)
      shift = reg(:shift_r, sw, reset: 0)
      algn = reg(:algn, width, reset: 0)

      win = wire(:win, cat([p1, code]))

      hits =
        for k <- (width - 1)..0//-1 do
          pat = slice(win, 2 * width - len - k, len)

          Enum.reduce(commas, nil, fn c, acc ->
            case acc do
              nil -> pat == c
              acc -> acc or pat == c
            end
          end)
        end

      cand =
        hits
        |> Enum.zip((width - 1)..0//-1)
        |> Enum.reduce(shift, fn {hit, k}, acc -> mux(hit, const(k, sw), acc) end)

      ext = wire(:ext, cat([p2, p1]))
      picks = for s <- 0..(width - 1), do: slice(ext, width - s, width)

      sync do
        p1 <~ code
        p2 <~ p1
        algn <~ mux(shift, picks)
        if not lock, do: shift <~ cand
      end

      aligned <~ algn
      shift_o <~ shift
      found <~ Enum.reduce(tl(hits), hd(hits), fn h, acc -> acc or h end)
    end
  end
end
