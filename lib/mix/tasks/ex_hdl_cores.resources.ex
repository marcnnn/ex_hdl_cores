defmodule Mix.Tasks.ExHdlCores.Resources do
  @shortdoc "Prints Yosys resource numbers of representative instances"
  @moduledoc "Usage: `mix ex_hdl_cores.resources [xc7 xcup]` (needs yosys in PATH)."
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    families = if args == [], do: ["xc7", "xcup"], else: args
    families |> ExHdlCores.Resources.run() |> ExHdlCores.Resources.table() |> Mix.shell().info()
  end
end
