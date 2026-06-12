defmodule BeamWatch.Incidents.SilenceTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Incidents.Silence

  describe "new/2" do
    test "creates an incident-scope silence" do
      silence = Silence.new(:incident, {:container_restart_loop, "plex"})
      assert silence.scope == :incident
      assert silence.key == {:container_restart_loop, "plex"}
    end

    test "creates a type-scope silence" do
      silence = Silence.new(:type, :container_restart_loop)
      assert silence.scope == :type
      assert silence.key == :container_restart_loop
    end

    test "creates silence with arbitrary key" do
      silence = Silence.new(:incident, {:disk_smart_warning, "3"})
      assert silence.scope == :incident
      assert silence.key == {:disk_smart_warning, "3"}
    end
  end
end
