defmodule BeamWatch.Incidents.Detectors.SharePermissionFailure do
  @behaviour BeamWatch.Incidents.Detector
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingest.Event

  @impl true
  def detect(state, event) do
    if permission_denied?(event) do
      share = Event.field(event, "share")
      timestamp = Event.at(event) || DateTime.utc_now()
      id = {:share_permission_failure, share}

      case Map.get(state.incidents, id) do
        nil ->
          incident =
            Incident.new(:share_permission_failure, share,
              severity: :medium,
              first_seen: timestamp,
              last_seen: timestamp,
              evidence: [event]
            )

          %{state | incidents: Map.put(state.incidents, id, incident)}

        existing ->
          evidence = append_evidence(existing.evidence, event)
          incident = %{existing | last_seen: timestamp, evidence: evidence}
          %{state | incidents: Map.put(state.incidents, id, incident)}
      end
    else
      state
    end
  end

  defp permission_denied?(event) do
    Event.field(event, "share") != nil &&
      (String.contains?(event.payload, "permission denied") ||
         String.contains?(event.payload, "Permission denied"))
  end

  defp append_evidence(evidence, event) do
    if Enum.any?(evidence, &(&1.raw == event.raw)) do
      evidence
    else
      [event | evidence]
    end
  end
end
