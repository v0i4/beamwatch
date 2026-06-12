defmodule Mix.Tasks.Beamwatch.FeedLogs do
  @moduledoc """
  Mix task that generates sample BeamWatch logs.
  """
  use Mix.Task

  alias BeamWatch.LogFeed.CLI

  @shortdoc "Writes sample BeamWatch logs to a local directory"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    CLI.main(args)
  end
end
