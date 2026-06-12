defmodule BeamWatch.LogFeed.RunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias BeamWatch.LogFeed.Entry
  alias BeamWatch.LogFeed.Runner

  test "run with function producer writes entries to disk" do
    target =
      Path.join(System.tmp_dir!(), "beamwatch-runner-#{System.unique_integer([:positive])}")

    try do
      producer = fn ->
        [
          %Entry{source: "test.log", delay_ms: 0, line: "hello"},
          %Entry{source: "test.log", delay_ms: 0, line: "world"}
        ]
      end

      capture_io(fn ->
        assert Runner.run(producer, target, 1000, false, []) == :ok
      end)

      assert File.read!(Path.join(target, "test.log")) == "hello\nworld\n"
    after
      File.rm_rf(target)
    end
  end

  test "run with list and loop writes entries repeatedly" do
    target =
      Path.join(System.tmp_dir!(), "beamwatch-runner-loop-#{System.unique_integer([:positive])}")

    try do
      entries = [
        %Entry{source: "loop.log", delay_ms: 0, line: "tick"}
      ]

      output =
        capture_io(fn ->
          task = Task.async(fn -> Runner.run(entries, target, 1000, true, []) end)
          Process.sleep(50)
          Task.shutdown(task, :brutal_kill)
        end)

      assert output =~ "loop.log"
      assert File.exists?(Path.join(target, "loop.log"))
    after
      File.rm_rf(target)
    end
  end
end
