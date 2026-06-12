defmodule BeamWatch.Ingest.EventTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Ingest.Event

  describe "at/1" do
    test "prefers the embedded log timestamp" do
      event = %Event{
        source: "docker.log",
        raw: "container=plex event=die",
        timestamp: ~U[2026-06-05 15:04:00Z],
        ingested_at: ~U[2026-06-05 16:00:00Z]
      }

      assert Event.at(event) == ~U[2026-06-05 15:04:00Z]
    end

    test "falls back to ingested_at when timestamp is nil" do
      event = %Event{
        source: "docker.log",
        raw: "container=plex event=die",
        timestamp: nil,
        ingested_at: ~U[2026-06-05 16:00:00Z]
      }

      assert Event.at(event) == ~U[2026-06-05 16:00:00Z]
    end

    test "returns nil when both timestamp and ingested_at are nil" do
      event = %Event{
        source: "docker.log",
        raw: "container=plex event=die",
        timestamp: nil,
        ingested_at: nil
      }

      assert Event.at(event) == nil
    end
  end

  describe "field/2" do
    test "returns a field value" do
      event = %Event{
        source: "docker.log",
        raw: "container=plex event=die",
        fields: %{"container" => "plex", "event" => "die"}
      }

      assert Event.field(event, "container") == "plex"
    end

    test "returns nil for missing field" do
      event = %Event{
        source: "docker.log",
        raw: "container=plex event=die",
        fields: %{"container" => "plex"}
      }

      assert Event.field(event, "missing") == nil
    end
  end
end
