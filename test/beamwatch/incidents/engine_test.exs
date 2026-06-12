defmodule BeamWatch.Incidents.EngineTest do
  use ExUnit.Case, async: false

  alias BeamWatch.Incidents.Engine
  alias BeamWatch.Ingest.Parser

  @topic_events "beamwatch:events"

  setup do
    pubsub_name = :"beamwatch_test_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name, pool_size: 1})
    %{pubsub_name: pubsub_name}
  end

  defp parse_validation_events do
    BeamWatch.LogFeed.Profiles.get("validation")
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
  end
end
