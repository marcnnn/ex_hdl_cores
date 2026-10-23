defmodule ExHdlCores.Scrambler do
  @moduledoc """
  Self-synchronising scramblers and additive PRBS generators over words of
  `width` bits per cycle, bit 0 first on the wire.

  The polynomial is a list of tap exponents without the constant term:
  `[58, 39]` is `x^58 + x^39 + 1` (10GBASE-R), `[7, 6]` is PRBS7 or the
  802.11 scrambler. The state is the last `n` (highest exponent) line bits,
  bit 0 the most recent.

    * `:scramble` - out = in xor state taps; the output enters the state
    * `:descramble` - out = in xor state taps; the input enters the state
    * `:prbs` - out = data xor sequence; the sequence bit enters the state
      (additive scrambler; with `data` 0 the output is the PRBS itself)

  `build/1` takes `poly:`, `width:` (default 64), `mode:` (default
  `:scramble`) and `seed:` (reset state, default all ones for `:scramble`
  and `:prbs`, 0 for `:descramble`) and has ports `data` (width), `en`,
  `out` (width, combinational from the state and `data`, latency 0). With
  `en` the state advances at the clock edge, without it the state holds.

  The XOR network comes from the bit-serial reference `step/4` by unit
  vectors at elaboration (`masks/3`); `matrix/3` does the same for any
  linear step function, for blocks with their own state layout.
  """
  use ExHdl.RTL
  alias Bitwise, as: B

  @doc """
  Reference: one word. Returns `{state, out}` after `width` bits of `data`
  from `state` in `mode` with taps `poly`.
  """
  def step(state, data, width, poly, mode \\ :scramble) do
    n = Enum.max(poly)
    mask = B.bsl(1, n) - 1

    Enum.reduce(0..(width - 1), {state, 0}, fn i, {s, out} ->
      fb = Enum.reduce(poly, 0, &B.bxor(&2, B.band(B.bsr(s, &1 - 1), 1)))
      d = B.band(B.bsr(data, i), 1)
      o = B.bxor(d, fb)

      shift_in =
        case mode do
          :scramble -> o
          :descramble -> d
          :prbs -> fb
        end

      {B.band(B.bor(B.bsl(s, 1), shift_in), mask), B.bor(out, B.bsl(o, i))}
    end)
  end

  @doc """
  Row masks of a linear step `f.(state, data) -> {state, out}` with
  `state_bits` and `data_bits` inputs: `%{ns_s:, ns_d:, o_s:, o_d:}`; bit
  `k` of the next state (output) is the parity of `state & ns_s[k]` xor
  `data & ns_d[k]` (`o_s[k]`, `o_d[k]`). The width of the output is taken
  from the largest column.
  """
  def matrix(f, state_bits, data_bits) do
    cs = for j <- 0..(state_bits - 1), do: f.(B.bsl(1, j), 0)
    cd = for i <- 0..(data_bits - 1), do: f.(0, B.bsl(1, i))

    row = fn cols, pick, k ->
      cols
      |> Enum.with_index()
      |> Enum.reduce(0, fn {col, j}, acc ->
        if B.band(B.bsr(pick.(col), k), 1) == 1, do: B.bor(acc, B.bsl(1, j)), else: acc
      end)
    end

    %{
      ns_s: for(k <- 0..(state_bits - 1), do: row.(cs, &elem(&1, 0), k)),
      ns_d: for(k <- 0..(state_bits - 1), do: row.(cd, &elem(&1, 0), k)),
      o_s: for(k <- 0..(data_bits - 1), do: row.(cs, &elem(&1, 1), k)),
      o_d: for(k <- 0..(data_bits - 1), do: row.(cd, &elem(&1, 1), k))
    }
  end

  @doc "Row masks (`matrix/3`) of `step/5` for a word of `width` bits."
  def masks(poly, width, mode \\ :scramble) do
    matrix(&step(&1, &2, width, poly, mode), Enum.max(poly), width)
  end

  @doc "Expressions `{next_state, out}` of the XOR network `m` (from `matrix/3`)."
  def network(state, data, m) do
    net = fn ms, md ->
      bits =
        for k <- (length(ms) - 1)..0//-1, do: xor_of(state, Enum.at(ms, k), data, Enum.at(md, k))

      rtl(do: cat(bits))
    end

    {net.(m.ns_s, m.ns_d), net.(m.o_s, m.o_d)}
  end

  defp xor_of(state, ms, data, md) do
    case {ms, md} do
      {0, 0} -> rtl(do: const(0, 1))
      {0, _} -> rtl(do: reduce_xor(data &&& md))
      {_, 0} -> rtl(do: reduce_xor(state &&& ms))
      _ -> rtl(do: bxor(reduce_xor(state &&& ms), reduce_xor(data &&& md)))
    end
  end

  @doc "Scrambler, descrambler or PRBS module; see the moduledoc."
  def build(opts) do
    poly = Keyword.fetch!(opts, :poly) |> Enum.sort(:desc) |> Enum.uniq()
    width = Keyword.get(opts, :width, 64)
    mode = Keyword.get(opts, :mode, :scramble)
    n = hd(poly)

    unless mode in [:scramble, :descramble, :prbs] and width >= 1 and Enum.all?(poly, &(&1 >= 1)),
      do: raise(ArgumentError, "scrambler: bad mode, width or poly")

    seed = Keyword.get(opts, :seed, if(mode == :descramble, do: 0, else: B.bsl(1, n) - 1))
    tag = Enum.map_join(poly, "_", &Integer.to_string/1)

    module "#{mode}_x#{tag}_w#{width}" do
      data = input(:data, width)
      en = input(:en, 1)
      out = output(:out, width)
      st = reg(:st, n, reset: seed)
      {ns, o} = network(st, data, masks(poly, width, mode))

      sync do
        if en, do: st <~ ns
      end

      out <~ o
    end
  end
end
