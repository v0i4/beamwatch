defmodule BeamWatch.LogFeed.CLITest do
  use ExUnit.Case, async: true

  alias BeamWatch.LogFeed.CLI

  test "main/1 returns :ok on success" do
    target =
      Path.join(System.tmp_dir!(), "beamwatch-cli-main-#{System.unique_integer([:positive])}")

    try do
      assert :ok =
               CLI.main([
                 "--profile",
                 "sample",
                 "--target",
                 target,
                 "--speed",
                 "1000",
                 "--quiet"
               ])

      assert File.exists?(target)
    after
      File.rm_rf(target)
    end
  end

  test "run/1 with invalid profile returns an error tuple" do
    assert {:error, "Profile not found: unknown"} = CLI.run(["--profile", "unknown"])
  end
end
