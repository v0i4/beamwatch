defmodule BeamWatch.Incidents.Detectors.SharePermissionFailureTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.SharePermissionFailure
  alias BeamWatch.Ingest.Parser

  defp event(line, opts \\ []) do
    source = Keyword.get(opts, :source, "smb.log")
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

  defp smb_denied_line(share, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()

    "#{ts} smbd[8112]: Permission denied share=#{share} user=guest path=/mnt/user/#{share}/private"
  end

  defp nfs_denied_line(share, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} nfsd: permission denied share=#{share} client=192.168.1.12"
  end

  defp benign_opened_line(share, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} smbd[8220]: user=alex opened share=#{share} path=/mnt/user/#{share}"
  end

  describe "detection" do
    test "opens incident on smb permission denied" do
      state =
        SharePermissionFailure.detect(empty_state(), event(smb_denied_line("media", 420)))

      assert map_size(state.incidents) == 1

      incident = state.incidents[{:share_permission_failure, "media"}]
      assert incident.type == :share_permission_failure
      assert incident.resource == "media"
      assert incident.severity == :medium
      assert incident.status == :active
    end

    test "opens incident on nfs permission denied" do
      state =
        SharePermissionFailure.detect(
          empty_state(),
          event(nfs_denied_line("media", 426), source: "nfs.log")
        )

      assert map_size(state.incidents) == 1
      assert state.incidents[{:share_permission_failure, "media"}]
    end

    test "updates existing incident with additional events" do
      state =
        [420, 426]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          if offset == 426 do
            SharePermissionFailure.detect(
              acc,
              event(nfs_denied_line("media", offset), source: "nfs.log")
            )
          else
            SharePermissionFailure.detect(acc, event(smb_denied_line("media", offset)))
          end
        end)

      incident = state.incidents[{:share_permission_failure, "media"}]
      assert length(incident.evidence) == 2
    end

    test "tracks different shares separately" do
      state =
        [smb_denied_line("media", 420), smb_denied_line("backups", 450)]
        |> Enum.reduce(empty_state(), fn line, acc ->
          SharePermissionFailure.detect(acc, event(line))
        end)

      assert map_size(state.incidents) == 2
    end
  end

  describe "benign non-triggers" do
    test "opened share line does not trigger" do
      state =
        SharePermissionFailure.detect(empty_state(), event(benign_opened_line("backups", 660)))

      assert state.incidents == %{}
    end

    test "line without 'share' field does not trigger" do
      line =
        "#{DateTime.add(base_time(), 420, :second) |> DateTime.to_iso8601()} smbd[8112]: Permission denied user=guest"

      state = SharePermissionFailure.detect(empty_state(), event(line))
      assert state.incidents == %{}
    end
  end

  describe "dedup" do
    test "duplicate raw lines are not added twice" do
      e = event(smb_denied_line("media", 420))
      state = SharePermissionFailure.detect(empty_state(), e)
      state = SharePermissionFailure.detect(state, e)

      incident = state.incidents[{:share_permission_failure, "media"}]
      assert length(incident.evidence) == 1
    end
  end
end
