defmodule BeamWatchWeb.DashboardLiveTest do
  use BeamWatchWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BeamWatch.Incidents.Engine
  alias BeamWatch.Ingest.Event

  setup do
    target =
      Path.join(System.tmp_dir!(), "beamwatch-dash-#{System.unique_integer([:positive])}")

    prev_target = Application.get_env(:beamwatch, :log_feed_target)
    prev_controls = Application.get_env(:beamwatch, :dev_log_controls)

    Application.put_env(:beamwatch, :log_feed_target, target)
    Application.put_env(:beamwatch, :dev_log_controls, true)

    Engine.clear()

    on_exit(fn ->
      restore_env(:log_feed_target, prev_target)
      restore_env(:dev_log_controls, prev_controls)
      File.rm_rf(target)
    end)

    {:ok, target: target}
  end

  test "renders dashboard with basic structure", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "BeamWatch"
    assert html =~ "No sources monitored yet."
    assert html =~ "Dev log controls"
  end

  test "renders incident after event triggers detection", %{conn: conn} do
    feed_container_restart_events("plex")
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Container Restart Loop"
    assert html =~ "plex"
    assert html =~ "HIGH"
  end

  test "acknowledge action updates incident status", %{conn: conn} do
    feed_container_restart_events("plex")
    {:ok, view, _html} = live(conn, ~p"/")
    Process.sleep(50)

    view |> element("button", "Acknowledge") |> render_click()
    Process.sleep(100)

    snapshot = Engine.snapshot()
    assert %{status: :acknowledged} = snapshot.incidents[{:container_restart_loop, "plex"}]
  end

  test "resolve action updates incident status", %{conn: conn} do
    feed_container_restart_events("plex")
    {:ok, view, _html} = live(conn, ~p"/")
    Process.sleep(50)

    view |> element("button", "Resolve") |> render_click()
    Process.sleep(100)

    snapshot = Engine.snapshot()
    assert %{status: :resolved} = snapshot.incidents[{:container_restart_loop, "plex"}]
  end

  test "silence-incident action creates incident silence", %{conn: conn} do
    feed_container_restart_events("plex")
    {:ok, view, _html} = live(conn, ~p"/")
    Process.sleep(50)

    view |> element("button", "Silence this") |> render_click()
    Process.sleep(100)

    snapshot = Engine.snapshot()
    assert Map.has_key?(snapshot.silences, {:incident, {:container_restart_loop, "plex"}})
    assert snapshot.incidents[{:container_restart_loop, "plex"}].silenced?
  end

  test "silence-type action creates type silence", %{conn: conn} do
    feed_container_restart_events("plex")
    {:ok, view, _html} = live(conn, ~p"/")
    Process.sleep(50)

    view |> element("button", "Silence type") |> render_click()
    Process.sleep(100)

    on_exit(fn ->
      Engine.clear_silence(:type, :container_restart_loop)
    end)

    snapshot = Engine.snapshot()
    assert Map.has_key?(snapshot.silences, {:type, :container_restart_loop})
  end

  test "clear-silence from incident action buttons removes silence and restores status",
       %{conn: conn} do
    feed_container_restart_events("plex")
    {:ok, view, _html} = live(conn, ~p"/")
    Process.sleep(50)

    view |> element("button", "Silence this") |> render_click()
    Process.sleep(100)

    snapshot = Engine.snapshot()
    assert snapshot.incidents[{:container_restart_loop, "plex"}].silenced?

    view |> element("button", "Clear silence") |> render_click()
    Process.sleep(100)

    snapshot = Engine.snapshot()
    refute snapshot.incidents[{:container_restart_loop, "plex"}].silenced?
    assert snapshot.incidents[{:container_restart_loop, "plex"}].status == :active
    refute Map.has_key?(snapshot.silences, {:incident, {:container_restart_loop, "plex"}})
  end

  test "silences panel renders with Clear button after silence-type action", %{conn: conn} do
    feed_container_restart_events("plex")
    {:ok, view, _html} = live(conn, ~p"/")
    Process.sleep(50)

    view |> element("button", "Silence type") |> render_click()
    Process.sleep(100)

    html = render(view)

    assert html =~ "Silences"
    assert html =~ "Container Restart Loop"
    assert html =~ "Clear"

    on_exit(fn ->
      Engine.clear_silence(:type, :container_restart_loop)
    end)
  end

  test "clear-silence from silences panel removes type silence", %{conn: conn} do
    feed_container_restart_events("plex")
    {:ok, view, _html} = live(conn, ~p"/")
    Process.sleep(50)

    view |> element("button", "Silence type") |> render_click()
    Process.sleep(100)

    html = render(view)
    assert html =~ "Silences"

    view
    |> element(~s|button[phx-click="clear-silence"][phx-value-scope="type"]|, "Clear")
    |> render_click()

    Process.sleep(100)

    snapshot = Engine.snapshot()
    refute Map.has_key?(snapshot.silences, {:type, :container_restart_loop})
  end

  test "silence-incident action sets incident status to silenced", %{conn: conn} do
    feed_container_restart_events("plex")
    {:ok, view, _html} = live(conn, ~p"/")
    Process.sleep(50)

    view |> element("button", "Silence this") |> render_click()
    Process.sleep(100)

    snapshot = Engine.snapshot()
    assert %{status: :silenced} = snapshot.incidents[{:container_restart_loop, "plex"}]
  end

  test "toggle-evidence expands and hides evidence pane", %{conn: conn} do
    feed_container_restart_events("plex")
    {:ok, view, html} = live(conn, ~p"/")
    Process.sleep(50)

    assert html =~ "Show evidence"

    view |> element("button", "Show evidence") |> render_click()
    Process.sleep(50)

    html = render(view)
    assert html =~ "Hide evidence"
  end

  test "Recent activity panel renders with placeholder text when empty", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Recent activity"
    assert html =~ "No recent activity"
  end

  test "starter shell panel renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "BeamWatch"
    assert html =~ "Live incident triage"
  end

  defp feed_container_restart_events(container) do
    base = DateTime.utc_now()

    for i <- 0..3 do
      ts = DateTime.add(base, i, :second)

      event = %Event{
        source: "docker.log",
        raw: "container=#{container} event=die",
        payload: "container=#{container} event=die",
        timestamp: ts,
        fields: %{"container" => container, "event" => "die"},
        ingested_at: ts
      }

      Phoenix.PubSub.broadcast(BeamWatch.PubSub, "beamwatch:events", {:beamwatch, :event, event})
    end

    Process.sleep(100)
  end

  defp restore_env(key, nil), do: Application.delete_env(:beamwatch, key)
  defp restore_env(key, value), do: Application.put_env(:beamwatch, key, value)
end
