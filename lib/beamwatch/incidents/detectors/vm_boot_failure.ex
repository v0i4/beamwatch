defmodule BeamWatch.Incidents.Detectors.VMBootFailure do
  @behaviour BeamWatch.Incidents.Detector
  @moduledoc false

  alias BeamWatch.Incidents.Incident
  alias BeamWatch.Ingest.Event

  @impl true
  def detect(state, event) do
    cond do
      boot_failure?(event) -> handle_boot_failure(state, event)
      supporting_event?(event) -> handle_supporting_event(state, event)
      true -> state
    end
  end

  defp boot_failure?(event) do
    event.source == "libvirt.log" &&
      Event.field(event, "status") == "failed" &&
      Event.field(event, "vm") != nil
  end

  defp supporting_event?(event) do
    has_vm_for_incident?(event) || qemu_permission_denied?(event)
  end

  defp has_vm_for_incident?(event) do
    Event.field(event, "vm") != nil && event.source != "libvirt.log"
  end

  defp qemu_permission_denied?(event) do
    event.source == "qemu.log" &&
      String.contains?(event.payload || "", "Permission denied")
  end

  defp handle_boot_failure(state, event) do
    vm = Event.field(event, "vm")
    timestamp = Event.at(event) || DateTime.utc_now()
    id = {:vm_boot_failure, vm}

    case Map.get(state.incidents, id) do
      nil ->
        incident =
          Incident.new(:vm_boot_failure, vm,
            severity: :high,
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
  end

  defp handle_supporting_event(state, event) do
    vm = supporting_vm(event)
    id = {:vm_boot_failure, vm}

    case Map.get(state.incidents, id) do
      nil -> state
      %{status: :resolved} -> state
      _ -> upsert_incident(state, vm, event)
    end
  end

  defp supporting_vm(event) do
    cond do
      Event.field(event, "vm") != nil -> Event.field(event, "vm")
      qemu_permission_denied?(event) -> extract_vm_from_qemu(event)
      true -> nil
    end
  end

  defp extract_vm_from_qemu(event) do
    case Event.field(event, "file") do
      nil ->
        nil

      path ->
        case Regex.run(~r{/domains/([^/]+)/}, path) do
          [_, vm] -> vm
          nil -> nil
        end
    end
  end

  defp upsert_incident(state, vm, event) do
    id = {:vm_boot_failure, vm}
    timestamp = Event.at(event) || DateTime.utc_now()

    case Map.get(state.incidents, id) do
      nil ->
        state

      existing ->
        evidence = append_evidence(existing.evidence, event)
        incident = %{existing | last_seen: timestamp, evidence: evidence}
        %{state | incidents: Map.put(state.incidents, id, incident)}
    end
  end

  defp append_evidence(evidence, event) do
    if Enum.any?(evidence, &(&1.raw == event.raw)) do
      evidence
    else
      [event | evidence]
    end
  end
end
