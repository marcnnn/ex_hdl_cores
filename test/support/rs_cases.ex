defmodule ExHdlCores.RsCases do
  @moduledoc false
  # Codewords for the Reed-Solomon tests, with the ex_sdr decode as the reference.
  import Bitwise
  alias ExSdr.Comm.ReedSolomon, as: RS

  def code(opts),
    do: RS.new(Keyword.take(opts, [:m, :field_poly, :n, :k, :fcr, :prim, :shortening]))

  @doc "A codeword (list of symbols) with `nerr` errors at random positions of the transmitted word."
  def word(code, nerr, kind \\ :random) do
    size = 1 <<< code.field.m
    len = RS.length(code)
    msg = for _ <- 1..RS.message_length(code), do: :rand.uniform(size) - 1

    case kind do
      :garbage ->
        for _ <- 1..len, do: :rand.uniform(size) - 1

      :random ->
        cw = RS.encode(code, msg)

        for p <- Enum.take_random(0..(len - 1), nerr), reduce: cw do
          cw -> List.update_at(cw, p, &bxor(&1, :rand.uniform(size - 1)))
        end
    end
  end

  @doc "Expected `{message, failed?, errors}` from the reference."
  def expect(code, word) do
    case RS.decode(code, word) do
      {:ok, msg, n} -> {msg, false, n}
      {:error, :uncorrectable, msg} -> {msg, true, 0}
    end
  end

  @doc "Mixed batch: clean, 1..t errors, t + 1 .. 2t + 4 errors and garbage."
  def batch(code, count, seed) do
    :rand.seed(:exsss, {seed, 8, 9})
    t = div(code.n - code.k, 2)

    for i <- 1..count do
      case rem(i, 6) do
        0 -> word(code, 0)
        1 -> word(code, t)
        2 -> word(code, :rand.uniform(t))
        3 -> word(code, t + 1 + :rand.uniform(t + 3))
        4 -> word(code, 0, :garbage)
        5 -> word(code, :rand.uniform(t))
      end
    end
  end
end
