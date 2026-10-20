defmodule ExHdlCores.Arbiter do
  @moduledoc """
  Arbiters over `n` requesters.

    * `fixed/2` - fixed priority, requester 0 first.
    * `round_robin/2` - after a grant is finished, requesters above the
      granted one go first; the first requester follows the last.

  Options: `hold:` `:none | :packet` and `ports:` the optional outputs to
  provide (default `[:idx, :valid]`; instances that leave an output
  unconnected should drop it, see NEEDS.md). Both are combinational from
  `req` to `grant` and share the ports:

    * `req` (n) - request lines (for a stream: the `tvalid`s)
    * `adv` (1) - the current grant is finished: a transfer happened
      (without `hold: :packet`) or the last beat of a packet did (with it)
    * `grant` (n) - one-hot, zero without requests; `idx` - its binary
      index; `valid` - some grant is active

  With `hold: :packet` the grant is held, even if the request drops,
  until `adv`: the packet-aware mode for stream mergers (`adv` is
  `tvalid & tready & tlast` of the merged output). Without it the grant
  follows the requests every cycle and `adv` only moves the round-robin
  pointer.

  `Model` is the cycle-accurate reference.
  """
  use ExHdl.RTL

  @doc "Fixed-priority arbiter (see the moduledoc). Options: `hold: :none | :packet`."
  def fixed(n, opts \\ []), do: build(:fixed, n, opts)

  @doc "Round-robin arbiter (see the moduledoc). Options: `hold: :none | :packet`."
  def round_robin(n, opts \\ []), do: build(:rr, n, opts)

  @doc "Lowest set bit of `x` as a one-hot expression."
  def lowest(x), do: rtl(do: x &&& inv(sub_wrap(x, 1)))

  # `~~~` of a wrapped sum is emitted as `~8'(a - 8'd1)`, which Yosys'
  # read_verilog rejects (NEEDS.md); XOR with all ones is the same logic.
  defp inv(x), do: rtl(do: bxor(x, Bitwise.bsl(1, width(x)) - 1))

  defp build(kind, n, opts) do
    hold = Keyword.get(opts, :hold, :none)
    ports = Keyword.get(opts, :ports, [:idx, :valid])
    unless n >= 1 and hold in [:none, :packet], do: raise(ArgumentError, "bad arbiter options")
    iw = max(ExHdl.RTL.Builder.ceil_log2(n), 1)
    tag = if kind == :fixed, do: "fixed", else: "rr"

    suffix =
      if ports == [:idx, :valid],
        do: "",
        else: "_p" <> Enum.map_join(ports, &(to_string(&1) |> String.first()))

    module "arb_#{tag}_#{n}#{if hold == :packet, do: "_pkt", else: ""}#{suffix}" do
      req = input(:req, n)
      adv = input(:adv, 1)
      grant = output(:grant, n)
      idx = if :idx in ports, do: output(:idx, iw)
      valid = if :valid in ports, do: output(:valid, 1)

      pick =
        case kind do
          :fixed ->
            lowest(req)

          :rr ->
            mask = reg(:mask, n, reset: Bitwise.bsl(1, n) - 1)
            masked = wire(:masked, req &&& mask)
            sel = wire(:sel, mux(reduce_or(masked), lowest(masked), lowest(req)))

            sync do
              if adv and reduce_or(grant), do: mask <~ inv(grant ||| sub_wrap(grant, 1))
            end

            sel
        end

      if hold == :packet do
        locked = reg(:locked, 1)
        held = reg(:held, n)
        sel = wire(:pick, pick)
        grant <~ mux(locked, held, sel)

        sync do
          if adv do
            locked <~ 0
          else
            if reduce_or(grant) do
              locked <~ 1
              held <~ grant
            end
          end
        end
      else
        grant <~ pick
      end

      if :valid in ports, do: valid <~ reduce_or(grant)

      if :idx in ports,
        do: idx <~ cat(for j <- (iw - 1)..0//-1, do: reduce_or(grant &&& index_mask(n, j)))
    end
  end

  # Bits whose index has bit `j` set.
  defp index_mask(n, j),
    do:
      Enum.reduce(0..(n - 1), 0, fn i, m ->
        if Bitwise.band(Bitwise.bsr(i, j), 1) == 1, do: Bitwise.bor(m, Bitwise.bsl(1, i)), else: m
      end)

  defmodule Model do
    @moduledoc """
    Cycle-accurate arbiter model. `new(kind, n, hold)`, then
    `step(state, req, adv)` returns `{state, %{grant:, idx:, valid:}}` for
    the inputs of one cycle (outputs are combinational, the state updates
    at the end of the cycle). `req` and `grant` are bit masks.
    """
    import Bitwise

    def new(kind, n, hold \\ :none),
      do: %{kind: kind, n: n, hold: hold, last: -1, held: nil}

    def step(m, req, adv) do
      adv = adv in [1, true]

      sel =
        case m.kind do
          :fixed -> lowest(req, 0, m.n)
          :rr -> lowest(req, m.last + 1, m.n) || lowest(req, 0, m.n)
        end

      grant =
        cond do
          m.hold == :packet and m.held != nil -> m.held
          true -> sel
        end

      grant = grant || 0
      idx = if grant == 0, do: 0, else: grant |> Integer.digits(2) |> length() |> Kernel.-(1)

      m =
        cond do
          adv and grant != 0 -> %{m | held: nil, last: idx}
          adv -> %{m | held: nil}
          grant != 0 and m.hold == :packet -> %{m | held: grant}
          true -> m
        end

      {m, %{grant: grant, idx: idx, valid: if(grant != 0, do: 1, else: 0)}}
    end

    defp lowest(req, from, n) do
      Enum.find_value(from..(n - 1)//1, fn i -> if (req >>> i &&& 1) == 1, do: 1 <<< i end)
    end
  end
end
