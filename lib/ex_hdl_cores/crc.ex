defmodule ExHdlCores.CRC do
  @moduledoc """
  Table-free CRC for any width, polynomial, reflection, init and final
  XOR (the Rocksoft model), `bytes` bytes per cycle.

  The state is the register of the bit-serial algorithm. One word of `k`
  bytes is a linear map over GF(2) of (state, data), so each next-state
  bit is the parity of a masked state word and a masked data word. The
  masks come from running the bit-serial algorithm on unit vectors
  (`matrices/2`); the hardware is the resulting XOR network.

  Ports of `build/1`:

    * `data` (8 * bytes), byte 0 in the low bits, as AXI4-Stream `tdata`
    * `keep` (bytes, only with `bytes > 1` and `keep: true`, the default):
      `tkeep`; the highest set bit gives the byte count of a partial last
      word, all-zero ignores the word
    * `valid` - process this word
    * `clear` - restart from `init` before this word (without `valid`:
      just restart)
    * `crc` - output, the CRC of all bytes since the last clear
      (reflection and final XOR applied), valid the cycle after the word

  `compute/2` is the bit-serial reference in plain Elixir; `check/1`
  holds the catalogue check values (CRC of `"123456789"`).
  """
  use ExHdl.RTL
  import Bitwise, only: [band: 2, bor: 2, bsl: 2, bsr: 2]

  defstruct [:width, :poly, init: 0, refin: false, refout: false, xorout: 0]

  @type t :: %__MODULE__{}

  # {width, poly, init, refin, refout, xorout, check}
  @presets %{
    crc32: {32, 0x04C11DB7, 0xFFFFFFFF, true, true, 0xFFFFFFFF, 0xCBF43926},
    crc32c: {32, 0x1EDC6F41, 0xFFFFFFFF, true, true, 0xFFFFFFFF, 0xE3069283},
    crc32_bzip2: {32, 0x04C11DB7, 0xFFFFFFFF, false, false, 0xFFFFFFFF, 0xFC891918},
    crc32_mpeg2: {32, 0x04C11DB7, 0xFFFFFFFF, false, false, 0, 0x0376E6E7},
    crc16_ccitt_false: {16, 0x1021, 0xFFFF, false, false, 0, 0x29B1},
    crc16_xmodem: {16, 0x1021, 0, false, false, 0, 0x31C3},
    crc16_kermit: {16, 0x1021, 0, true, true, 0, 0x2189},
    crc16_arc: {16, 0x8005, 0, true, true, 0, 0xBB3D},
    crc16_modbus: {16, 0x8005, 0xFFFF, true, true, 0, 0x4B37},
    crc8: {8, 0x07, 0, false, false, 0, 0xF4},
    crc5_usb: {5, 0x05, 0x1F, true, true, 0x1F, 0x19},
    crc64_xz:
      {64, 0x42F0E1EBA9EA3693, 0xFFFFFFFFFFFFFFFF, true, true, 0xFFFFFFFFFFFFFFFF,
       0x995DC9BBDF1939FA}
  }

  @doc "Names of the catalogue presets."
  def presets, do: @presets |> Map.keys() |> Enum.sort()

  @doc "The parameters of a preset (`:crc32`, `:crc32c`, `:crc16_ccitt_false`, ...)."
  @spec preset(atom()) :: t()
  def preset(name) do
    {w, poly, init, refin, refout, xorout, _} =
      Map.get(@presets, name) || raise ArgumentError, "unknown CRC preset #{inspect(name)}"

    %__MODULE__{width: w, poly: poly, init: init, refin: refin, refout: refout, xorout: xorout}
  end

  @doc "CRC of `\"123456789\"` for a preset."
  def check(name), do: @presets |> Map.fetch!(name) |> elem(6)

  @doc """
  Parameters from a preset atom, a `%CRC{}` or keywords (`width:`, `poly:`,
  `init:`, `refin:`, `refout:`, `xorout:`; or `preset:` plus overrides).
  """
  @spec params(atom() | t() | keyword()) :: t()
  def params(%__MODULE__{} = c), do: validate!(c)
  def params(name) when is_atom(name), do: name |> preset() |> validate!()

  def params(opts) when is_list(opts) do
    base = if p = opts[:preset], do: preset(p), else: %__MODULE__{}
    keys = [:width, :poly, :init, :refin, :refout, :xorout]
    validate!(struct(base, Keyword.take(opts, keys)))
  end

  defp validate!(%{width: w, poly: p, init: i, xorout: x} = c) do
    unless is_integer(w) and w in 2..64, do: raise(ArgumentError, "CRC width must be 2..64")

    for {n, v} <- [poly: p, init: i, xorout: x] do
      unless is_integer(v) and v >= 0 and v < bsl(1, w),
        do: raise(ArgumentError, "CRC #{n} must fit in #{w} bits")
    end

    c
  end

  # -- reference model -------------------------------------------------------------------

  @doc "Reference CRC of a binary (bit-serial, one byte at a time)."
  @spec compute(atom() | t() | keyword(), binary()) :: non_neg_integer()
  def compute(c, bin) do
    c = params(c)
    c |> state_of(bin) |> finalize(c)
  end

  @doc "The state register after `bin`, starting from `init`."
  def state_of(%__MODULE__{} = c, bin, reg \\ nil),
    do: for(<<b <- bin>>, reduce: reg || c.init, do: (r -> step_word(c, r, b, 1)))

  @doc "Reflection and final XOR of a state register."
  def finalize(%__MODULE__{} = c, reg), do: finalize(reg, c)

  def finalize(reg, %__MODULE__{} = c) when is_integer(reg),
    do: Bitwise.bxor(if(c.refout, do: reflect(reg, c.width), else: reg), c.xorout)

  @doc "One step over `k` bytes of `data` (byte 0 in the low bits) from state `reg`."
  def step_word(%__MODULE__{} = c, reg, data, k) do
    Enum.reduce(0..(k - 1)//1, reg, fn i, reg ->
      byte = band(bsr(data, 8 * i), 0xFF)
      byte = if c.refin, do: reflect(byte, 8), else: byte
      top = bsl(1, c.width - 1)
      mask = bsl(1, c.width) - 1

      Enum.reduce(7..0//-1, reg, fn j, reg ->
        fb = Bitwise.bxor(bsr(band(reg, top), c.width - 1), band(bsr(byte, j), 1))
        reg = band(bsl(reg, 1), mask)
        if fb == 1, do: Bitwise.bxor(reg, c.poly), else: reg
      end)
    end)
  end

  @doc "Reverses the low `w` bits of `v`."
  def reflect(v, w),
    do: Enum.reduce(0..(w - 1), 0, fn i, acc -> bor(acc, bsl(band(bsr(v, i), 1), w - 1 - i)) end)

  @doc """
  The XOR network for `k` bytes per word: `%{state: masks, data: masks}`,
  one mask per next-state bit (index 0 = LSB). Bit `j` of the next state
  is `parity(state & state[j]) ^ parity(data & data[j])`.
  """
  def matrices(c, k) do
    c = params(c)
    w = c.width

    masks = fn n, f ->
      cols = for i <- 0..(n - 1), do: f.(bsl(1, i))

      for j <- 0..(w - 1) do
        cols
        |> Enum.with_index()
        |> Enum.reduce(0, fn {v, i}, acc -> bor(acc, bsl(band(bsr(v, j), 1), i)) end)
      end
    end

    %{
      state: masks.(w, &step_word(c, &1, 0, k)),
      data: masks.(8 * k, &step_word(c, 0, &1, k))
    }
  end

  # -- hardware --------------------------------------------------------------------------

  @doc """
  The CRC module. `params` as in `params/1`; options: `bytes:` (data bus
  bytes, default 1), `keep:` (add the `keep` port, default true when
  `bytes > 1`), `name:` (module name, derived from the parameters by
  default).
  """
  def build(params, opts \\ []) do
    c = params(params)
    bytes = Keyword.get(opts, :bytes, 1)
    keep? = Keyword.get(opts, :keep, bytes > 1) and bytes > 1
    w = c.width

    name =
      Keyword.get_lazy(opts, :name, fn ->
        h = fn v -> Integer.to_string(v, 16) end

        "crc#{w}_#{h.(c.poly)}_#{h.(c.init)}_#{h.(c.xorout)}_#{if c.refin, do: "r", else: "n"}" <>
          "#{if c.refout, do: "r", else: "n"}_b#{bytes}#{if keep?, do: "k", else: ""}"
      end)

    mats = for k <- 1..bytes, into: %{}, do: {k, matrices(c, k)}

    module name do
      data = input(:data, 8 * bytes)
      keep = if keep?, do: input(:keep, bytes)
      valid = input(:valid, 1)
      clear = input(:clear, 1)
      crc = output(:crc, w)
      state = reg(:state, w, reset: c.init)
      fresh = wire(:fresh, mux(clear, const(c.init, w), state))

      nexts =
        for k <- 1..bytes do
          %{state: sm, data: dm} = mats[k]
          dk = data[0..(8 * k - 1)]

          bits =
            for j <- (w - 1)..0//-1 do
              bxor(reduce_xor(fresh &&& Enum.at(sm, j)), reduce_xor(dk &&& Enum.at(dm, j)))
            end

          cat(bits)
        end

      next =
        if keep? do
          # the highest set bit of keep gives the byte count
          nexts
          |> Enum.with_index(1)
          |> Enum.reduce(nil, fn
            {n, 1}, nil -> n
            {n, k}, acc -> mux(keep[k - 1], n, acc)
          end)
        else
          List.last(nexts)
        end

      next = wire(:next, next)
      active = if keep?, do: valid and reduce_or(keep), else: valid

      sync do
        if active do
          state <~ next
        else
          if clear, do: state <~ c.init
        end
      end

      final = if c.refout, do: cat(for(i <- 0..(w - 1), do: state[i])), else: state
      crc <~ if(c.xorout == 0, do: final, else: bxor(final, c.xorout))
    end
  end
end
