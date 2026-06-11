defmodule BeamWatchWeb.TelemetryTest do
  use ExUnit.Case, async: true

  test "metrics/0 returns a list of telemetry metrics" do
    metrics = BeamWatchWeb.Telemetry.metrics()
    assert is_list(metrics)
    refute Enum.empty?(metrics)

    assert Enum.any?(metrics, fn m ->
             m.__struct__ == Telemetry.Metrics.Summary &&
               m.event_name == [:phoenix, :endpoint, :stop]
           end)

    assert Enum.any?(metrics, fn m ->
             m.__struct__ == Telemetry.Metrics.Summary &&
               m.event_name == [:vm, :memory]
           end)
  end
end
