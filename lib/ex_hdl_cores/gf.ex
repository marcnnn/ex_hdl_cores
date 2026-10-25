defmodule ExHdlCores.GF do
  @moduledoc """
  GF(2^m) arithmetic for Reed-Solomon cores: integer reference functions
  and hardware expressions for the same operations.

  Elements are integers `0..2^m - 1` in the polynomial basis (bit `i` is the
  coefficient of `alpha^i`); the field polynomial is given with its `x^m`
  term (`0x11D` for GF(256) in DVB). `alpha = 2` must be primitive.

  A multiplication by a constant is a linear map of the bits, hence an XOR
  network: `const_mul/3`. The general product `mul_expr/3` is an AND-XOR
  array built from the same maps, one per bit of the second operand.
  """
  use ExHdl.RTL
  alias Bitwise, as: B

  defstruct [:m, :poly, :exp, :log]

  @doc "The field for `m` bits and primitive polynomial `poly`."
  def new(m, poly) when m in 2..16 do
    size = B.bsl(1, m)

    {exp, log, _} =
      Enum.reduce(0..(size - 2), {[], %{}, 1}, fn i, {exp, log, x} ->
        next = B.bsl(x, 1)
        next = if next >= size, do: B.bxor(next, poly), else: next
        {[x | exp], Map.put(log, x, i), next}
      end)

    if map_size(log) != size - 1,
      do:
        raise(ArgumentError, "GF: 0x#{Integer.to_string(poly, 16)} is not primitive for m = #{m}")

    %__MODULE__{m: m, poly: poly, exp: exp |> Enum.reverse() |> List.to_tuple(), log: log}
  end

  @doc "Multiplicative order of the field, `2^m - 1`."
  def order(%__MODULE__{m: m}), do: B.bsl(1, m) - 1

  def mul(_f, 0, _), do: 0
  def mul(_f, _, 0), do: 0
  def mul(f, a, b), do: elem(f.exp, rem(f.log[a] + f.log[b], order(f)))

  @doc "Inverse; 0 for 0 (as the hardware table)."
  def inv(_f, 0), do: 0
  def inv(f, a), do: elem(f.exp, Integer.mod(-f.log[a], order(f)))

  @doc "`alpha^i`, any integer `i`."
  def pow(f, i), do: elem(f.exp, Integer.mod(i, order(f)))

  @doc """
  Row masks of the linear map `x -> c * x`: bit `k` of the product is the
  parity of `x &&& masks[k]`.
  """
  def masks(%__MODULE__{m: m} = f, c) do
    cols = for j <- 0..(m - 1), do: mul(f, c, B.bsl(1, j))

    for k <- 0..(m - 1) do
      cols
      |> Enum.with_index()
      |> Enum.reduce(0, fn {col, j}, acc -> B.bor(acc, B.bsl(B.band(B.bsr(col, k), 1), j)) end)
    end
  end

  @doc "Hardware `c * x` for the constant `c` (an XOR network, wires for 1)."
  def const_mul(%__MODULE__{m: m} = f, x, c) do
    case c do
      0 ->
        rtl(do: const(0, m))

      1 ->
        x

      _ ->
        bits = f |> masks(c) |> Enum.reverse() |> Enum.map(&parity(x, &1))
        rtl(do: cat(bits))
    end
  end

  @doc "Hardware product of two `m` bit signals."
  def mul_expr(%__MODULE__{m: m} = f, a, b) do
    rows = for j <- 0..(m - 1), do: masks(f, B.bsl(1, j))

    bits =
      for k <- (m - 1)..0//-1 do
        terms =
          for {row, j} <- Enum.with_index(rows), mask = Enum.at(row, k), mask != 0 do
            p = parity(a, mask)
            rtl(do: p &&& b[j])
          end

        xor_all(terms)
      end

    rtl(do: cat(bits))
  end

  @doc "Parity of `x &&& mask` as a bit."
  def parity(x, mask) do
    case mask do
      0 -> rtl(do: const(0, 1))
      _ -> rtl(do: reduce_xor(x &&& mask))
    end
  end

  @doc "XOR of a list of expressions (`nil` for an empty list is a zero bit)."
  def xor_all([]), do: rtl(do: const(0, 1))
  def xor_all(list), do: xor_tree(list)

  defp xor_tree([x]), do: x

  defp xor_tree(list) do
    {a, b} = Enum.split(list, div(length(list) + 1, 2))
    l = xor_tree(a)
    r = xor_tree(b)
    rtl(do: bxor(l, r))
  end

  @doc "Inverse table as a list of `2^m` integers."
  def inverse_table(%__MODULE__{m: m} = f), do: for(x <- 0..(B.bsl(1, m) - 1), do: inv(f, x))
end
