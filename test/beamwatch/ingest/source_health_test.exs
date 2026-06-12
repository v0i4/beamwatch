defmodule BeamWatch.Ingest.SourceHealthTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Ingest.SourceHealth

  describe "new/1" do
    test "creates a fresh health record with defaults" do
      health = SourceHealth.new("docker.log")

      assert health.source == "docker.log"
      assert health.exists? == false
      assert health.size == nil
      assert health.offset == nil
      assert health.last_read_at == nil
      assert health.last_event_at == nil
      assert health.parse_failures == 0
      assert health.malformed_samples == []
      assert health.rotations == 0
      assert health.truncated? == false
    end
  end

  describe "summary/1" do
    test "shows source, exists?, size and offset" do
      health = %SourceHealth{
        source: "app.log",
        exists?: true,
        size: 4096,
        offset: 2048
      }

      assert SourceHealth.summary(health) ==
               "app.log exists=true size=4096 offset=2048"
    end

    test "uses ? for nil size" do
      health = %SourceHealth{source: "syslog.log", exists?: false}
      assert SourceHealth.summary(health) =~ "size=?"
    end

    test "uses ? for nil offset" do
      health = %SourceHealth{source: "syslog.log", exists?: false}
      assert SourceHealth.summary(health) =~ "offset=?"
    end

    test "handles all fields nil" do
      health = SourceHealth.new("unknown.log")
      summary = SourceHealth.summary(health)
      assert summary =~ "unknown.log"
      assert summary =~ "exists=false"
      assert summary =~ "size=?"
      assert summary =~ "offset=?"
    end
  end
end
