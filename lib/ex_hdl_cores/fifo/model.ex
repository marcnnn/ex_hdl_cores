defmodule ExHdlCores.FIFO.Model do
  @moduledoc """
  Reference model of a FIFO's contents: a bounded queue. The FIFOs differ
  in how many cycles a pushed entry takes to appear at the output (see
  `ExHdlCores.FIFO`), but never in order, `count` or `full`; tests compare
  these against the model cycle by cycle.
  """
  defstruct depth: 16, queue: :queue.new()

  @type t :: %__MODULE__{}

  def new(depth), do: %__MODULE__{depth: depth}

  @doc "Entries stored."
  def count(%__MODULE__{queue: q}), do: :queue.len(q)

  def full?(%__MODULE__{} = m), do: count(m) == m.depth
  def empty?(%__MODULE__{} = m), do: count(m) == 0

  @doc "The oldest entry, or nil."
  def head(%__MODULE__{queue: q}), do: with({:value, v} <- :queue.peek(q), do: v)

  @doc """
  One cycle: `push` is a value or nil, `pop` a boolean. A push while full
  (even with a simultaneous pop) and a pop while empty are ignored.
  Returns `{model, popped_value | nil}`.
  """
  def step(%__MODULE__{} = m, push, pop) do
    room = not full?(m)

    {m, popped} =
      if pop and not empty?(m) do
        {{:value, v}, q} = :queue.out(m.queue)
        {%{m | queue: q}, v}
      else
        {m, nil}
      end

    m = if push != nil and room, do: %{m | queue: :queue.in(push, m.queue)}, else: m
    {m, popped}
  end
end
