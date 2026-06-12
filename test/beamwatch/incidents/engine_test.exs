defmodule BeamWatch.Incidents.EngineTest do
  use ExUnit.Case, async: false

  alias BeamWatch.Incidents.Engine
  alias BeamWatch.Ingest.Parser
  alias BeamWatch.LogFeed.Profiles

  @topic_events "beamwatch:events"

  setup do
    # credo:disable-for-this-line
    pubsub_name = :"beamwatch_test_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name, pool_size: 1})
    %{pubsub_name: pubsub_name}
  end

  defp parse_validation_events do
    Profiles.get("validation")
    |> Enum.map(fn entry ->
      case Parser.parse(entry.line, source: entry.source) do
        {:ok, event} -> {:ok, event}
        {:malformed, _raw, _reason} -> :malformed
      end
    end)
  end

  defp validation_events do
    parse_validation_events()
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, event} -> event end)
  end

  describe "detector integration" do
    test "processing all validation events creates four incidents", %{pubsub_name: pubsub_name} do
      {:ok, pid} =
        Engine.start_link(
          pubsub: pubsub_name,
          # credo:disable-for-this-line
          name: :"engine_test_#{System.unique_integer([:positive])}"
        )

      events = validation_events()

      Enum.each(events, fn event ->
        Phoenix.PubSub.broadcast(pubsub_name, @topic_events, {:beamwatch, :event, event})
        Process.sleep(5)
      end)

      Process.sleep(20)
      snapshot = Engine.snapshot(pid)
      assert map_size(snapshot.incidents) == 4
    end

    test "incident types are correct", %{pubsub_name: pubsub_name} do
      {:ok, pid} =
        Engine.start_link(
          pubsub: pubsub_name,
          # credo:disable-for-this-line
          name: :"engine_test_#{System.unique_integer([:positive])}"
        )

      events = validation_events()

      Enum.each(events, fn event ->
        Phoenix.PubSub.broadcast(pubsub_name, @topic_events, {:beamwatch, :event, event})
        Process.sleep(5)
      end)

      Process.sleep(20)
      snapshot = Engine.snapshot(pid)
      types = Map.values(snapshot.incidents) |> Enum.map(& &1.type) |> MapSet.new()

      assert MapSet.equal?(
               types,
               MapSet.new([
                 :container_restart_loop,
                 :disk_smart_warning,
                 :share_permission_failure,
                 :vm_boot_failure
               ])
             )
    end
  end

  describe "operator actions" do
    test "acknowledge changes incident status", %{pubsub_name: pubsub_name} do
      {:ok, pid} =
        Engine.start_link(
          pubsub: pubsub_name,
          # credo:disable-for-this-line
          name: :"engine_test_#{System.unique_integer([:positive])}"
        )

      events = validation_events()

      Enum.each(events, fn event ->
        Phoenix.PubSub.broadcast(pubsub_name, @topic_events, {:beamwatch, :event, event})
        Process.sleep(5)
      end)

      Process.sleep(20)
      snapshot = Engine.snapshot(pid)
      {id, _incident} = Enum.at(snapshot.incidents, 0)

      :ok = Engine.acknowledge(pid, id)
      Process.sleep(5)

      snapshot = Engine.snapshot(pid)
      assert snapshot.incidents[id].status == :acknowledged
    end

    test "resolve changes incident status", %{pubsub_name: pubsub_name} do
      {:ok, pid} =
        Engine.start_link(
          pubsub: pubsub_name,
          # credo:disable-for-this-line
          name: :"engine_test_#{System.unique_integer([:positive])}"
        )

      events = validation_events()

      Enum.each(events, fn event ->
        Phoenix.PubSub.broadcast(pubsub_name, @topic_events, {:beamwatch, :event, event})
        Process.sleep(5)
      end)

      Process.sleep(20)
      snapshot = Engine.snapshot(pid)
      {id, _incident} = Enum.at(snapshot.incidents, 1)

      :ok = Engine.resolve(pid, id)
      Process.sleep(5)

      snapshot = Engine.snapshot(pid)
      assert snapshot.incidents[id].status == :resolved
    end

    test "disk smart warning auto-resolves", %{pubsub_name: pubsub_name} do
      {:ok, pid} =
        Engine.start_link(
          pubsub: pubsub_name,
          # credo:disable-for-this-line
          name: :"engine_test_#{System.unique_integer([:positive])}"
        )

      events = validation_events()

      Enum.each(events, fn event ->
        Phoenix.PubSub.broadcast(pubsub_name, @topic_events, {:beamwatch, :event, event})
        Process.sleep(5)
      end)

      Process.sleep(20)
      snapshot = Engine.snapshot(pid)

      disk_incident = snapshot.incidents[{:disk_smart_warning, "3"}]
      assert disk_incident.status == :resolved
    end

    test "silence by incident sets status to silenced and records silence", %{
      pubsub_name: pubsub_name
    } do
      {:ok, pid} =
        Engine.start_link(
          pubsub: pubsub_name,
          # credo:disable-for-this-line
          name: :"engine_test_#{System.unique_integer([:positive])}"
        )

      events = validation_events()

      Enum.each(events, fn event ->
        Phoenix.PubSub.broadcast(pubsub_name, @topic_events, {:beamwatch, :event, event})
        Process.sleep(5)
      end)

      Process.sleep(20)
      snapshot = Engine.snapshot(pid)
      {id, _incident} = Enum.at(snapshot.incidents, 0)

      :ok = Engine.silence(pid, :incident, id)
      Process.sleep(5)

      snapshot = Engine.snapshot(pid)
      assert snapshot.incidents[id].status == :silenced
      assert snapshot.incidents[id].silenced? == true
      assert Map.has_key?(snapshot.silences, {:incident, id})
    end

    test "silence by type silences all incidents of that type", %{pubsub_name: pubsub_name} do
      {:ok, pid} =
        Engine.start_link(
          pubsub: pubsub_name,
          # credo:disable-for-this-line
          name: :"engine_test_#{System.unique_integer([:positive])}"
        )

      events = validation_events()

      Enum.each(events, fn event ->
        Phoenix.PubSub.broadcast(pubsub_name, @topic_events, {:beamwatch, :event, event})
        Process.sleep(5)
      end)

      Process.sleep(20)

      :ok = Engine.silence(pid, :type, :container_restart_loop)
      Process.sleep(5)

      snapshot = Engine.snapshot(pid)
      assert Map.has_key?(snapshot.silences, {:type, :container_restart_loop})

      silenced_incidents =
        snapshot.incidents
        |> Map.values()
        |> Enum.filter(&(&1.type == :container_restart_loop))

      assert silenced_incidents != []

      Enum.each(silenced_incidents, fn inc ->
        assert inc.status == :silenced
        assert inc.silenced? == true
      end)
    end

    test "clear_silence for incident restores status to active", %{pubsub_name: pubsub_name} do
      {:ok, pid} =
        Engine.start_link(
          pubsub: pubsub_name,
          # credo:disable-for-this-line
          name: :"engine_test_#{System.unique_integer([:positive])}"
        )

      events = validation_events()

      Enum.each(events, fn event ->
        Phoenix.PubSub.broadcast(pubsub_name, @topic_events, {:beamwatch, :event, event})
        Process.sleep(5)
      end)

      Process.sleep(20)
      snapshot = Engine.snapshot(pid)
      {id, _incident} = Enum.at(snapshot.incidents, 0)

      :ok = Engine.silence(pid, :incident, id)
      Process.sleep(5)
      :ok = Engine.clear_silence(pid, :incident, id)
      Process.sleep(5)

      snapshot = Engine.snapshot(pid)
      assert snapshot.incidents[id].status == :active
      assert snapshot.incidents[id].silenced? == false
      refute Map.has_key?(snapshot.silences, {:incident, id})
    end

    test "clear_silence for type restores all incidents of that type to active", %{
      pubsub_name: pubsub_name
    } do
      {:ok, pid} =
        Engine.start_link(
          pubsub: pubsub_name,
          # credo:disable-for-this-line
          name: :"engine_test_#{System.unique_integer([:positive])}"
        )

      events = validation_events()

      Enum.each(events, fn event ->
        Phoenix.PubSub.broadcast(pubsub_name, @topic_events, {:beamwatch, :event, event})
        Process.sleep(5)
      end)

      Process.sleep(20)

      :ok = Engine.silence(pid, :type, :share_permission_failure)
      Process.sleep(5)
      :ok = Engine.clear_silence(pid, :type, :share_permission_failure)
      Process.sleep(5)

      snapshot = Engine.snapshot(pid)
      refute Map.has_key?(snapshot.silences, {:type, :share_permission_failure})

      restored_incidents =
        snapshot.incidents
        |> Map.values()
        |> Enum.filter(&(&1.type == :share_permission_failure))

      assert restored_incidents != []

      Enum.each(restored_incidents, fn inc ->
        assert inc.status == :active
        assert inc.silenced? == false
      end)
    end
  end
end
