defmodule BeamWatch.Incidents.Detectors.ContainerRestartLoop do
  @behaviour BeamWatch.Incidents.Detector
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingest.Event

  @impl true
  def detect(state, event) do
    cond do
      die_event?(event) -> handle_die_event(state, event)
      supporting_event?(event) -> handle_supporting_event(state, event)
      true -> state
    end
  end

  defp die_event?(event) do
    event.source == "docker.log" && Event.field(event, "event") == "die"
  end

  defp supporting_event?(event) do
    (event.source == "app.log" &&
       Event.field(event, "service") != nil &&
       String.contains?(event.payload, "healthcheck failed")) ||
      (event.source == "nginx.log" && upstream_unavailable?(event)) ||
      (event.source == "docker.log" && Event.field(event, "event") == "start")
  end

  defp upstream_unavailable?(event) do
    String.contains?(event.payload, "upstream") &&
      String.contains?(event.payload, "unavailable")
  end

  defp handle_die_event(state, event) do
    container = Event.field(event, "container")

    scratch = buffer_event(state, container, event)
    state = put_scratch(state, scratch)

    buffered = Map.get(scratch, container, [])

    if threshold_reached?(buffered) do
      id = {:container_restart_loop, container}

      case Map.get(state.incidents, id) do
        nil -> open_incident(state, container, buffered)
        _ -> upsert_incident(state, container, event, :high)
      end
    else
      state
    end
  end

  defp handle_supporting_event(state, event) do
    container = supporting_container(event)
    id = {:container_restart_loop, container}

    case Map.get(state.incidents, id) do
      nil ->
        scratch = buffer_event(state, container, event)
        put_scratch(state, scratch)

      %{status: :resolved} ->
        state

      _ ->
        upsert_incident(state, container, event, :high)
    end
  end

  defp supporting_container(event) do
    cond do
      event.source == "app.log" -> Event.field(event, "service")
      event.source == "nginx.log" -> extract_upstream_name(event)
      event.source == "docker.log" -> Event.field(event, "container")
    end
  end

  defp extract_upstream_name(event) do
    case Regex.run(~r/upstream\s+(\S+)\s+unavailable/, event.payload) do
      [_, name] -> name
      nil -> nil
    end
  end

  defp buffer_event(state, container, event) do
    scratch = Map.get(state.detector_scratch, __MODULE__, %{})
    events = [event | Map.get(scratch, container, [])]
    pruned = prune_events(events)
    Map.put(scratch, container, pruned)
  end

  defp prune_events(events) do
    now = DateTime.utc_now()
    timestamps = Enum.map(events, &Event.at/1) |> Enum.reject(&is_nil/1)

    latest = if timestamps == [], do: now, else: Enum.max(timestamps)
    cutoff = DateTime.add(latest, -120, :second)

    Enum.filter(events, fn e ->
      t = Event.at(e)
      is_nil(t) || DateTime.compare(t, cutoff) != :lt
    end)
  end

  defp threshold_reached?(buffered_events) do
    die_timestamps =
      buffered_events
      |> Enum.filter(&die_event?(&1))
      |> Enum.map(&Event.at(&1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    die_timestamps
    |> Enum.chunk_every(4, 1, :discard)
    |> Enum.any?(fn group ->
      DateTime.diff(List.last(group), List.first(group), :second) <= 60
    end)
  end

  defp open_incident(state, container, buffered_events) do
    id = {:container_restart_loop, container}
    events = Enum.uniq_by(buffered_events, & &1.raw)
    timestamp = events |> List.first() |> Event.at() || DateTime.utc_now()

    incident =
      Incident.new(:container_restart_loop, container,
        severity: :high,
        first_seen: timestamp,
        last_seen: timestamp,
        evidence: events
      )

    scratch = Map.get(state.detector_scratch, __MODULE__, %{})
    scratch = Map.delete(scratch, container)
    state = put_scratch(state, scratch)

    %{state | incidents: Map.put(state.incidents, id, incident)}
  end

  defp upsert_incident(state, container, event, severity) do
    id = {:container_restart_loop, container}
    timestamp = Event.at(event) || DateTime.utc_now()
    existing = Map.get(state.incidents, id)

    incident =
      case existing do
        nil ->
          Incident.new(:container_restart_loop, container,
            severity: severity,
            first_seen: timestamp,
            last_seen: timestamp,
            evidence: [event]
          )

        _ ->
          evidence = append_evidence(existing.evidence, event)
          %{existing | last_seen: timestamp, evidence: evidence}
      end

    %{state | incidents: Map.put(state.incidents, id, incident)}
  end

  defp append_evidence(evidence, event) do
    if Enum.any?(evidence, &(&1.raw == event.raw)) do
      evidence
    else
      [event | evidence]
    end
  end

  defp put_scratch(state, scratch) do
    put_in(state, [:detector_scratch, __MODULE__], scratch)
  end
end
