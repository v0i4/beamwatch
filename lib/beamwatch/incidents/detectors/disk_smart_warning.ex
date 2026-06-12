defmodule BeamWatch.Incidents.Detectors.DiskSmartWarning do
  @behaviour BeamWatch.Incidents.Detector
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingest.Event

  @warning_re ~r/emhttpd:\s+disk(\d+)\s+SMART\s+warning:/
  @pass_re ~r/emhttpd:\s+disk(\d+)\s+SMART\s+check\s+passed/

  @impl true
  def detect(state, event) do
    cond do
      smart_warning?(event) -> handle_warning(state, event)
      smart_pass?(event) -> handle_pass(state, event)
      true -> state
    end
  end

  defp smart_warning?(event) do
    event.source == "syslog.log" && Regex.match?(@warning_re, event.payload)
  end

  defp smart_pass?(event) do
    event.source == "syslog.log" && Regex.match?(@pass_re, event.payload)
  end

  defp extract_disk(event) do
    result = Regex.run(@warning_re, event.payload) || Regex.run(@pass_re, event.payload)

    case result do
      [_, disk] -> disk
      nil -> nil
    end
  end

  defp handle_warning(state, event) do
    disk = extract_disk(event)
    timestamp = Event.at(event) || DateTime.utc_now()
    id = {:disk_smart_warning, disk}

    case Map.get(state.incidents, id) do
      nil ->
        incident =
          Incident.new(:disk_smart_warning, disk,
            severity: :medium,
            first_seen: timestamp,
            last_seen: timestamp,
            evidence: [event]
          )

        %{state | incidents: Map.put(state.incidents, id, incident)}

      existing ->
        evidence = append_evidence(existing.evidence, event)
        severity = escalate_severity(existing, event)
        incident = %{existing | last_seen: timestamp, evidence: evidence, severity: severity}
        %{state | incidents: Map.put(state.incidents, id, incident)}
    end
  end

  defp handle_pass(state, event) do
    disk = extract_disk(event)
    id = {:disk_smart_warning, disk}

    case Map.get(state.incidents, id) do
      nil ->
        state

      incident ->
        evidence = append_evidence(incident.evidence, event)

        incident = %{
          incident
          | status: :resolved,
            last_seen: Event.at(event) || DateTime.utc_now(),
            evidence: evidence
        }

        %{state | incidents: Map.put(state.incidents, id, incident)}
    end
  end

  defp escalate_severity(incident, _event) do
    warning_count =
      Enum.count(incident.evidence, fn e ->
        Regex.match?(@warning_re, e.payload)
      end)

    if warning_count + 1 >= 3, do: :high, else: :medium
  end

  defp append_evidence(evidence, event) do
    if Enum.any?(evidence, &(&1.raw == event.raw)) do
      evidence
    else
      [event | evidence]
    end
  end
end
