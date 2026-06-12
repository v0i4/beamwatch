defmodule BeamWatch.Incidents.Detectors.VMBootFailureTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Detectors.VMBootFailure
  alias BeamWatch.Ingest.Parser

  defp event(line, opts \\ []) do
    source = Keyword.get(opts, :source, "libvirt.log")
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

  defp boot_failure_line(vm, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()

    ~s(#{ts} vm=#{vm} action=start status=failed reason="cannot access storage image /mnt/user/domains/#{vm}/vdisk1.img")
  end

  defp port_missing_line(vm, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} kernel: br0: port missing for vm=#{vm}"
  end

  defp qemu_denied_line(vm, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} qemu-system-x86_64: -drive file=/mnt/user/domains/#{vm}/vdisk1.img: Permission denied"
  end

  defp running_line(vm, offset_seconds) do
    ts = DateTime.add(base_time(), offset_seconds, :second) |> DateTime.to_iso8601()
    "#{ts} vm=#{vm} action=start status=running"
  end

  describe "detection" do
    test "opens incident on libvirt boot failure" do
      state =
        VMBootFailure.detect(empty_state(), event(boot_failure_line("windows11", 480)))

      assert map_size(state.incidents) == 1

      incident = state.incidents[{:vm_boot_failure, "windows11"}]
      assert incident.type == :vm_boot_failure
      assert incident.resource == "windows11"
      assert incident.severity == :high
      assert incident.status == :active
    end

    test "two different VMs create separate incidents" do
      state =
        [boot_failure_line("windows11", 480), boot_failure_line("ubuntu", 500)]
        |> Enum.reduce(empty_state(), fn line, acc ->
          VMBootFailure.detect(acc, event(line))
        end)

      assert map_size(state.incidents) == 2
    end
  end

  describe "supporting evidence" do
    test "syslog port missing event attaches to open incident" do
      state = VMBootFailure.detect(empty_state(), event(boot_failure_line("windows11", 480)))
      pe = event(port_missing_line("windows11", 482), source: "syslog.log")
      state = VMBootFailure.detect(state, pe)

      incident = state.incidents[{:vm_boot_failure, "windows11"}]
      assert length(incident.evidence) == 2
      assert hd(incident.evidence).payload =~ "br0: port missing"
    end

    test "qemu permission denied attaches to open incident" do
      state = VMBootFailure.detect(empty_state(), event(boot_failure_line("windows11", 480)))
      qe = event(qemu_denied_line("windows11", 484), source: "qemu.log")
      state = VMBootFailure.detect(state, qe)

      incident = state.incidents[{:vm_boot_failure, "windows11"}]
      assert length(incident.evidence) == 2
      assert hd(incident.evidence).payload =~ "Permission denied"
    end
  end

  describe "no auto-resolve" do
    test "status=running does NOT auto-resolve the incident" do
      state = VMBootFailure.detect(empty_state(), event(boot_failure_line("windows11", 480)))
      re = event(running_line("windows11", 728))
      state = VMBootFailure.detect(state, re)

      incident = state.incidents[{:vm_boot_failure, "windows11"}]
      assert incident.status == :active
    end
  end

  describe "benign non-triggers" do
    test "successful boot for debian-dev does not trigger" do
      state =
        VMBootFailure.detect(empty_state(), event(running_line("debian-dev", 780)))

      assert state.incidents == %{}
    end

    test "qemu permission denied without open incident is ignored" do
      qe = event(qemu_denied_line("windows11", 484), source: "qemu.log")
      state = VMBootFailure.detect(empty_state(), qe)
      assert state.incidents == %{}
    end
  end

  describe "dedup" do
    test "duplicate raw lines are not added twice" do
      e = event(boot_failure_line("windows11", 480))
      state = VMBootFailure.detect(empty_state(), e)
      state = VMBootFailure.detect(state, e)

      incident = state.incidents[{:vm_boot_failure, "windows11"}]
      assert length(incident.evidence) == 1
    end
  end
end
