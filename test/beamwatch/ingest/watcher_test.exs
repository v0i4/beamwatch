defmodule BeamWatch.Ingest.WatcherTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Ingest.{Event, Watcher}

  setup do
    dir = Path.join(System.tmp_dir!(), "beamwatch_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp start_watcher(dir) do
    name = :"test_watcher_#{System.unique_integer([:positive])}"
    {:ok, pid} = Watcher.start_link(dir: dir, reconcile_interval: 60_000, name: name)
    pid
  end

  defp subscribe do
    Phoenix.PubSub.subscribe(BeamWatch.PubSub, "beamwatch:events")
    Phoenix.PubSub.subscribe(BeamWatch.PubSub, "beamwatch:health")
  end

  defp wait_for_event(timeout) do
    receive do
      {:beamwatch, :event, event} -> {:ok, event}
    after
      timeout -> :timeout
    end
  end

  defp wait_for_health(timeout) do
    receive do
      {:beamwatch, :health, health} -> {:ok, health}
    after
      timeout -> :timeout
    end
  end

  defp drain_events(acc \\ []) do
    case wait_for_event(100) do
      {:ok, event} -> drain_events([event | acc])
      :timeout -> Enum.reverse(acc)
    end
  end

  defp drain_health(acc \\ []) do
    case wait_for_health(100) do
      {:ok, health} -> drain_health([health | acc])
      :timeout -> Enum.reverse(acc)
    end
  end

  describe "existing files at startup" do
    test "start at EOF and do not emit old events", %{dir: dir} do
      path = Path.join(dir, "docker.log")
      File.write!(path, "2026-06-05T15:04:00Z container=plex event=die\n")

      subscribe()
      pid = start_watcher(dir)

      # Nothing emitted immediately.
      assert wait_for_event(200) == :timeout

      # Reconcile also shouldn't emit old lines.
      Watcher.reconcile(pid)
      assert wait_for_event(200) == :timeout

      sources = Watcher.sources(pid)
      health = Map.fetch!(sources, "docker.log")
      assert health.offset == 46
      assert health.exists? == true
    end
  end

  describe "new lines" do
    test "emits events for appended lines and advances offset", %{dir: dir} do
      path = Path.join(dir, "docker.log")
      File.write!(path, "2026-06-05T15:04:00Z container=plex event=die\n")

      pid = start_watcher(dir)
      subscribe()

      # Append a new line.
      File.write!(path, "2026-06-05T15:04:10Z container=plex event=die\n", [:append])

      Watcher.reconcile(pid)

      assert {:ok, event} = wait_for_event(500)
      assert event.source == "docker.log"
      assert event.fields["container"] == "plex"
      assert event.fields["event"] == "die"
      assert Event.at(event) == ~U[2026-06-05 15:04:10Z]

      sources = Watcher.sources(pid)
      health = Map.fetch!(sources, "docker.log")
      assert health.offset == 92
      assert health.exists? == true
    end
  end

  describe "new files after startup" do
    test "reads from the beginning", %{dir: dir} do
      pid = start_watcher(dir)
      subscribe()

      # Create a new file after the watcher has started.
      path = Path.join(dir, "smb.log")
      File.write!(path, "2026-06-05T15:07:00Z smbd[8112]: Permission denied share=media\n")

      Watcher.reconcile(pid)

      assert {:ok, event} = wait_for_event(500)
      assert event.source == "smb.log"
      assert event.fields["share"] == "media"

      sources = Watcher.sources(pid)
      health = Map.fetch!(sources, "smb.log")
      assert health.offset == 63
    end
  end

  describe "rotation and truncation" do
    test "detects rotation when the file shrinks", %{dir: dir} do
      path = Path.join(dir, "syslog.log")
      # Make the original file larger than the replacement.
      File.write!(
        path,
        "2026-06-05T15:06:00Z emhttpd: disk3 SMART warning Reallocated_Sector_Ct raw=28 threshold=10\n"
      )

      pid = start_watcher(dir)
      subscribe()

      # Truncate the file to a smaller line.
      File.write!(path, "2026-06-05T15:06:01Z emhttpd: disk3 SMART check passed\n")

      Watcher.reconcile(pid)

      # Should pick up the new line after resetting offset.
      events = drain_events()
      assert length(events) == 1
      assert hd(events).payload =~ "SMART check passed"

      sources = Watcher.sources(pid)
      health = Map.fetch!(sources, "syslog.log")
      assert health.rotations == 1
      assert health.truncated? == true
    end
  end

  describe "malformed lines" do
    test "surfaces malformed lines in source health without crashing", %{dir: dir} do
      pid = start_watcher(dir)
      subscribe()

      path = Path.join(dir, "app.log")
      File.write!(path, "not-a-timestamp service=plex healthcheck\n")
      File.write!(path, "2026-06-05T15:04:00Z container=plex event=die\n", [:append])

      Watcher.reconcile(pid)

      # One valid event, one malformed.
      events = drain_events()
      assert length(events) == 1
      assert hd(events).source == "app.log"

      sources = Watcher.sources(pid)
      health = Map.fetch!(sources, "app.log")
      assert health.parse_failures == 1
      assert health.malformed_samples == ["not-a-timestamp service=plex healthcheck"]
    end
  end

  describe "incomplete lines" do
    test "holds back a line that does not end with newline", %{dir: dir} do
      pid = start_watcher(dir)
      subscribe()

      path = Path.join(dir, "docker.log")
      # Write without trailing newline.
      File.write!(path, "2026-06-05T15:04:00Z container=plex event=die")

      Watcher.reconcile(pid)

      assert wait_for_event(200) == :timeout

      sources = Watcher.sources(pid)
      health = Map.fetch!(sources, "docker.log")
      # Offset should not have advanced because the line is incomplete.
      assert health.offset == 0

      # Now append the newline.
      File.write!(path, "\n", [:append])
      Watcher.reconcile(pid)

      assert {:ok, event} = wait_for_event(500)
      assert event.fields["container"] == "plex"
    end
  end

  describe "source health updates" do
    test "broadcasts health on every reconcile", %{dir: dir} do
      path = Path.join(dir, "qemu.log")
      File.write!(path, "2026-06-05T15:08:00Z qemu-system-x86_64: Permission denied\n")

      pid = start_watcher(dir)
      subscribe()
      Watcher.reconcile(pid)

      healths = drain_health()
      qemu_health = Enum.find(healths, &(&1.source == "qemu.log"))
      assert qemu_health != nil
      assert qemu_health.exists? == true
      assert qemu_health.size == 59
    end
  end

  describe "multiple files" do
    test "tracks each file independently", %{dir: dir} do
      File.write!(Path.join(dir, "a.log"), "2026-06-05T15:00:00Z msg=a\n")
      File.write!(Path.join(dir, "b.log"), "2026-06-05T15:00:01Z msg=b\n")

      pid = start_watcher(dir)
      subscribe()

      sources = Watcher.sources(pid)
      assert map_size(sources) == 2
      assert sources["a.log"].offset == 27
      assert sources["b.log"].offset == 27

      # No events on startup because both start at EOF.
      assert wait_for_event(200) == :timeout
    end
  end
end
