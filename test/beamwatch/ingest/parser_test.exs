defmodule BeamWatch.Ingest.ParserTest do
  use ExUnit.Case, async: true

  alias BeamWatch.Ingest.Event
  alias BeamWatch.Ingest.Parser

  describe "parse/2 with well-formed lines" do
    test "parses a docker die line into structured fields" do
      assert {:ok, event} =
               Parser.parse("2026-06-05T15:04:00Z container=plex event=die exit_code=137",
                 source: "docker.log"
               )

      assert event.source == "docker.log"
      assert event.timestamp == ~U[2026-06-05 15:04:00Z]
      assert event.payload == "container=plex event=die exit_code=137"
      assert event.fields == %{"container" => "plex", "event" => "die", "exit_code" => "137"}
    end

    test "parses an smb permission line" do
      line =
        "2026-06-05T15:07:00Z smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private"

      assert {:ok, event} = Parser.parse(line, source: "smb.log")
      assert event.fields["share"] == "media"
      assert event.fields["user"] == "guest"
      assert event.fields["path"] == "/mnt/user/media/private"
      assert event.payload =~ "Permission denied"
    end

    test "captures quoted values that contain spaces" do
      line =
        ~s(2026-06-05T15:08:00Z vm=windows11 action=start status=failed reason="cannot access storage image /mnt/user/domains/windows11/vdisk1.img")

      assert {:ok, event} = Parser.parse(line, source: "libvirt.log")
      assert event.fields["vm"] == "windows11"
      assert event.fields["status"] == "failed"

      assert event.fields["reason"] ==
               "cannot access storage image /mnt/user/domains/windows11/vdisk1.img"
    end

    test "keeps SMART warnings whose disk is embedded in free text" do
      line =
        "2026-06-05T15:06:00Z emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10"

      assert {:ok, event} = Parser.parse(line, source: "syslog.log")
      assert event.payload =~ "disk3 SMART warning"
      assert event.fields["raw"] == "28"
      assert event.fields["threshold"] == "10"
      refute Map.has_key?(event.fields, "disk")
    end

    test "preserves a qemu drive path that ends with text" do
      line =
        "2026-06-05T15:08:04Z qemu-system-x86_64: -drive file=/mnt/user/domains/windows11/vdisk1.img: Permission denied"

      assert {:ok, event} = Parser.parse(line, source: "qemu.log")
      assert event.fields["file"] == "/mnt/user/domains/windows11/vdisk1.img:"
      assert event.payload =~ "Permission denied"
    end

    test "strips a trailing newline from the raw line" do
      assert {:ok, event} =
               Parser.parse("2026-06-05T15:00:00Z emhttpd: Array Started\n", source: "syslog.log")

      refute String.ends_with?(event.raw, "\n")
      assert event.raw == "2026-06-05T15:00:00Z emhttpd: Array Started"
    end

    test "records the provided ingestion time" do
      ingested_at = ~U[2026-06-05 16:00:00Z]

      assert {:ok, event} =
               Parser.parse("2026-06-05T15:00:00Z container=plex event=start",
                 source: "docker.log",
                 ingested_at: ingested_at
               )

      assert event.ingested_at == ingested_at
    end
  end

  describe "parse/2 with malformed lines" do
    test "flags a line without a parseable timestamp" do
      assert {:malformed, raw, :no_timestamp} =
               Parser.parse("not-a-timestamp service=plex healthcheck", source: "app.log")

      assert raw == "not-a-timestamp service=plex healthcheck"
    end

    test "flags an incomplete timestamp with no payload" do
      assert {:malformed, _raw, :no_timestamp} =
               Parser.parse("2026-06-05T15:16", source: "smb.log")
    end

    test "flags a truncated key=value at end of line" do
      assert {:malformed, _raw, :truncated} =
               Parser.parse("2026-06-05T15:16:00Z emhttpd: disk=", source: "syslog.log")
    end

    test "flags a truncated drive directive" do
      assert {:malformed, _raw, :truncated} =
               Parser.parse("2026-06-05T15:16:05Z qemu-system-x86_64: -drive file=",
                 source: "qemu.log"
               )
    end

    test "flags an empty payload after a valid timestamp" do
      assert {:malformed, _raw, :empty_payload} =
               Parser.parse("2026-06-05T15:00:00Z", source: "syslog.log")
    end

    test "flags blank lines" do
      assert {:malformed, _raw, :blank} = Parser.parse("   \n", source: "syslog.log")
    end
  end

  describe "Event.at/1 timestamp fallback" do
    test "prefers the embedded log timestamp" do
      assert {:ok, event} =
               Parser.parse("2026-06-05T15:04:00Z container=plex event=die",
                 source: "docker.log",
                 ingested_at: ~U[2026-06-05 16:00:00Z]
               )

      assert Event.at(event) == ~U[2026-06-05 15:04:00Z]
    end

    test "falls back to ingestion time when there is no embedded timestamp" do
      event = %Event{
        source: "docker.log",
        raw: "container=plex event=die",
        timestamp: nil,
        ingested_at: ~U[2026-06-05 16:00:00Z]
      }

      assert Event.at(event) == ~U[2026-06-05 16:00:00Z]
    end
  end

  describe "Event.field/2" do
    test "returns a field value or nil" do
      assert {:ok, event} =
               Parser.parse("2026-06-05T15:04:00Z container=plex event=die", source: "docker.log")

      assert Event.field(event, "container") == "plex"
      assert Event.field(event, "missing") == nil
    end
  end
end
