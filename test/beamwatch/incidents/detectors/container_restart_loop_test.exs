defmodule BeamWatch.Incidents.Detectors.ContainerRestartLoopTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.ContainerRestartLoop
  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingest.Parser

  defp event(line, opts \\ []) do
    source = Keyword.get(opts, :source, "docker.log")
    {:ok, event} = Parser.parse(line, source: source)
    event
  end

  defp base_time do
    ~U[2026-06-05 15:00:00Z]
  end

  defp state_with_scratch(scratch) do
    %{
      incidents: %{},
      silences: %{},
      recent_activity: [],
      detector_scratch: %{ContainerRestartLoop => scratch},
      pubsub: nil
    }
  end

  defp empty_state do
    state_with_scratch(%{})
  end

  defp die_line(container, offset_seconds, exit_code \\ "137") do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} container=#{container} event=die exit_code=#{exit_code}"
  end

  defp healthcheck_failed_line(service, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} service=#{service} healthcheck failed path=/identity request_id=#{service}-1"
  end

  defp upstream_unavailable_line(upstream, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} upstream #{upstream} unavailable request_id=#{upstream}-1"
  end

  defp start_line(container, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} container=#{container} event=start"
  end

  describe "threshold detection" do
    test "three die events within 60 seconds does not create an incident" do
      state =
        [0, 20, 40]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          ContainerRestartLoop.detect(acc, event(die_line("plex", offset)))
        end)

      assert state.incidents == %{}
    end

    test "four die events within 60 seconds creates a container_restart_loop incident" do
      state =
        [0, 20, 40, 55]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          ContainerRestartLoop.detect(acc, event(die_line("plex", offset)))
        end)

      assert %Incident{
               type: :container_restart_loop,
               resource: "plex",
               severity: :high,
               status: :active
             } = state.incidents[{:container_restart_loop, "plex"}]
    end

    test "four die events spread beyond 60 seconds does not trigger" do
      state =
        [0, 20, 40, 65]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          ContainerRestartLoop.detect(acc, event(die_line("plex", offset)))
        end)

      assert state.incidents == %{}
    end

    test "multiple batches of die events can trigger after the 4th within window" do
      state =
        [0, 20, 40, 55]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          ContainerRestartLoop.detect(acc, event(die_line("plex", offset)))
        end)

      assert map_size(state.incidents) == 1
    end

    test "benign single die event for home-assistant does not trigger" do
      state =
        ContainerRestartLoop.detect(empty_state(), event(die_line("home-assistant", 0, "0")))

      assert state.incidents == %{}
    end
  end

  describe "supporting evidence" do
    test "healthcheck failed attaches to existing incident" do
      state =
        [0, 20, 40, 55]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          ContainerRestartLoop.detect(acc, event(die_line("plex", offset)))
        end)

      hc_event = event(healthcheck_failed_line("plex", 58), source: "app.log")
      state = ContainerRestartLoop.detect(state, hc_event)

      incident = state.incidents[{:container_restart_loop, "plex"}]
      assert length(incident.evidence) == 5
      assert hd(incident.evidence).payload =~ "healthcheck failed"
    end

    test "upstream unavailable attaches to existing incident" do
      state =
        [0, 20, 40, 55]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          ContainerRestartLoop.detect(acc, event(die_line("plex", offset)))
        end)

      upstream_event = event(upstream_unavailable_line("plex", 60), source: "nginx.log")
      state = ContainerRestartLoop.detect(state, upstream_event)

      incident = state.incidents[{:container_restart_loop, "plex"}]
      assert hd(incident.evidence).payload =~ "upstream plex unavailable"
    end

    test "container start attaches to existing incident" do
      state =
        [0, 20, 40, 55]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          ContainerRestartLoop.detect(acc, event(die_line("plex", offset)))
        end)

      start_evt = event(start_line("plex", 62))
      state = ContainerRestartLoop.detect(state, start_evt)

      incident = state.incidents[{:container_restart_loop, "plex"}]
      assert hd(incident.evidence).payload =~ "event=start"
    end

    test "supporting evidence does not attach when no incident exists" do
      state = empty_state()
      hc_event = event(healthcheck_failed_line("plex", 58), source: "app.log")
      state = ContainerRestartLoop.detect(state, hc_event)
      assert state.incidents == %{}
    end
  end

  describe "dedup" do
    test "duplicate raw lines are not added to evidence twice" do
      state =
        [0, 20, 40, 55]
        |> Enum.reduce(empty_state(), fn offset, acc ->
          ContainerRestartLoop.detect(acc, event(die_line("plex", offset)))
        end)

      hc_event = event(healthcheck_failed_line("plex", 58), source: "app.log")
      state = ContainerRestartLoop.detect(state, hc_event)
      state = ContainerRestartLoop.detect(state, hc_event)

      incident = state.incidents[{:container_restart_loop, "plex"}]
      assert length(incident.evidence) == 5
    end
  end
end
