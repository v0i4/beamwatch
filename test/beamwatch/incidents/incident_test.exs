defmodule BeamWatch.Incidents.IncidentTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Incident

  describe "new/2" do
    test "creates an incident with default values" do
      incident = Incident.new(:container_restart_loop, "plex")

      assert incident.id == {:container_restart_loop, "plex"}
      assert incident.type == :container_restart_loop
      assert incident.resource == "plex"
      assert incident.severity == :medium
      assert incident.status == :active
      assert incident.evidence == []
      assert incident.silenced? == false
      assert %DateTime{} = incident.first_seen
      assert %DateTime{} = incident.last_seen
    end
  end

  describe "new/3 with options" do
    test "sets custom severity" do
      incident = Incident.new(:vm_boot_failure, "windows11", severity: :high)
      assert incident.severity == :high
    end

    test "sets custom first_seen and last_seen" do
      first = ~U[2026-06-05 14:00:00Z]
      last = ~U[2026-06-05 15:00:00Z]
      incident = Incident.new(:disk_smart_warning, "3", first_seen: first, last_seen: last)
      assert incident.first_seen == first
      assert incident.last_seen == last
    end

    test "sets silenced? flag" do
      incident = Incident.new(:share_permission_failure, "media", silenced?: true)
      assert incident.silenced? == true
    end

    test "accepts evidence list" do
      evidence = [%{source: "test.log", raw: "test line", fields: %{}}]
      incident = Incident.new(:container_restart_loop, "plex", evidence: evidence)
      assert incident.evidence == evidence
    end
  end

  describe "id generation" do
    test "id matches {type, resource} tuple" do
      incident = Incident.new(:vm_boot_failure, "ubuntu")
      assert incident.id == {:vm_boot_failure, "ubuntu"}
    end

    test "two incidents with same type and resource share the same id" do
      a = Incident.new(:container_restart_loop, "plex")
      b = Incident.new(:container_restart_loop, "plex")
      assert a.id == b.id
    end
  end

  describe "status defaults" do
    test "always starts as :active" do
      assert Incident.new(:container_restart_loop, "plex").status == :active
      assert Incident.new(:disk_smart_warning, "1").status == :active
      assert Incident.new(:share_permission_failure, "backups").status == :active
      assert Incident.new(:vm_boot_failure, "debian").status == :active
    end
  end
end
