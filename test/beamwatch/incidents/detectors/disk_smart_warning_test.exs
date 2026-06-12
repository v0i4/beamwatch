defmodule BeamWatch.Incidents.Detectors.DiskSmartWarningTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.DiskSmartWarning
  alias BeamWatch.Ingest.Parser

  defp event(line, opts \\ []) do
    source = Keyword.get(opts, :source, "syslog.log")
    {:ok, event} = Parser.parse(line, source: source)
    event
  end

  defp base_time do
    ~U[2026-06-05 15:00:00Z]
  end

  defp empty_state do
    %{
      incidents: %{},
      silences: %{},
      recent_activity: [],
      detector_scratch: %{},
      pubsub: nil
    }
  end

  defp warning_line(disk, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} emhttpd: disk#{disk} SMART warning: Reallocated_Sector_Ct raw=28 threshold=10"
  end

  defp pass_line(disk, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} emhttpd: disk#{disk} SMART check passed"
  end

  describe "detection" do
    test "opens incident on first SMART warning" do
      state = DiskSmartWarning.detect(empty_state(), event(warning_line("3", 360)))
      assert map_size(state.incidents) == 1

      incident = state.incidents[{:disk_smart_warning, "3"}]
      assert incident.type == :disk_smart_warning
      assert incident.resource == "3"
      assert incident.severity == :medium
      assert incident.status == :active
    end

    test "updates incident on subsequent SMART warning for same disk" do
      state =
        [360, 378]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          DiskSmartWarning.detect(acc, event(warning_line("3", offset)))
        end)

      incident = state.incidents[{:disk_smart_warning, "3"}]
      assert length(incident.evidence) == 2
    end
  end

  describe "auto-resolve" do
    test "SMART check passed auto-resolves the incident" do
      state = DiskSmartWarning.detect(empty_state(), event(warning_line("3", 360)))
      state = DiskSmartWarning.detect(state, event(pass_line("3", 1500)))

      incident = state.incidents[{:disk_smart_warning, "3"}]
      assert incident.status == :resolved
    end

    test "SMART check passed without prior warning is ignored" do
      state = DiskSmartWarning.detect(empty_state(), event(pass_line("3", 1500)))
      assert state.incidents == %{}
    end
  end

  describe "benign non-triggers" do
    test "disk1 SMART check passed does not trigger a warning incident" do
      state = DiskSmartWarning.detect(empty_state(), event(pass_line("1", 610)))
      assert state.incidents == %{}
    end

    test "smartctl PASSED output does not trigger" do
      line =
        "#{DateTime.add(base_time(), 603, :second) |> DateTime.to_iso8601()} smartctl exited with code 0: SMART overall-health self-assessment test result: PASSED device=/dev/nvme0n1"

      state = DiskSmartWarning.detect(empty_state(), event(line, source: "unraid-dev.log"))
      assert state.incidents == %{}
    end
  end

  describe "severity escalation" do
    test "severity escalates to high after three SMART warnings" do
      state =
        [360, 378, 400]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          DiskSmartWarning.detect(acc, event(warning_line("3", offset)))
        end)

      incident = state.incidents[{:disk_smart_warning, "3"}]
      assert incident.severity == :high
    end

    test "severity stays medium with fewer than three warnings" do
      state =
        [360, 378]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          DiskSmartWarning.detect(acc, event(warning_line("3", offset)))
        end)

      incident = state.incidents[{:disk_smart_warning, "3"}]
      assert incident.severity == :medium
    end
  end

  describe "dedup" do
    test "duplicate raw lines are not added twice" do
      e = event(warning_line("3", 360))
      state = DiskSmartWarning.detect(empty_state(), e)
      state = DiskSmartWarning.detect(state, e)

      incident = state.incidents[{:disk_smart_warning, "3"}]
      assert length(incident.evidence) == 1
    end
  end
end
