defmodule BeamWatchWeb.DashboardLive do
  use BeamWatchWeb, :live_view

  alias BeamWatch.Incidents.Engine
  alias BeamWatch.Ingest.Event
  alias BeamWatch.LogFeed.DevControls

  @topic_state "beamwatch:state"
  @topic_health "beamwatch:health"

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(BeamWatch.PubSub, @topic_state)
    Phoenix.PubSub.subscribe(BeamWatch.PubSub, @topic_health)

    snapshot = Engine.snapshot()

    {:ok,
     assign(socket,
       incidents: snapshot.incidents,
       silences: snapshot.silences,
       recent_activity: snapshot.recent_activity,
       source_health: %{},
       expanded_incidents: MapSet.new(),
       dev_log_controls_enabled?: DevControls.enabled?(),
       log_feed_target: Path.relative_to_cwd(DevControls.target_dir())
     )}
  end

  @impl true
  def handle_info({:beamwatch, :updated}, socket) do
    snapshot = Engine.snapshot()

    {:noreply,
     assign(socket,
       incidents: snapshot.incidents,
       silences: snapshot.silences,
       recent_activity: snapshot.recent_activity
     )}
  end

  @impl true
  def handle_info({:beamwatch, :health, health}, socket) do
    {:noreply,
     assign(
       socket,
       source_health: Map.put(socket.assigns.source_health, health.source, health)
     )}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle-evidence", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_incidents

    expanded =
      if MapSet.member?(expanded, id) do
        MapSet.delete(expanded, id)
      else
        MapSet.put(expanded, id)
      end

    {:noreply, assign(socket, expanded_incidents: expanded)}
  end

  def handle_event("acknowledge", %{"id" => id}, socket) do
    Engine.acknowledge(decode_id(id))
    {:noreply, socket}
  end

  def handle_event("silence-incident", %{"id" => id}, socket) do
    Engine.silence(:incident, decode_id(id))
    {:noreply, socket}
  end

  def handle_event("silence-type", %{"type" => type}, socket) do
    Engine.silence(:type, String.to_existing_atom(type))
    {:noreply, socket}
  end

  def handle_event("resolve", %{"id" => id}, socket) do
    Engine.resolve(decode_id(id))
    {:noreply, socket}
  end

  def handle_event("clear-silence", %{"scope" => scope, "key" => key}, socket) do
    scope = String.to_existing_atom(scope)

    key =
      case scope do
        :incident -> decode_id(key)
        :type -> String.to_existing_atom(key)
      end

    Engine.clear_silence(scope, key)
    {:noreply, socket}
  end

  def handle_event("dev-add-validation-logs", _params, socket) do
    if socket.assigns.dev_log_controls_enabled? do
      :ok = DevControls.add_validation_logs()

      {:noreply,
       put_flash(socket, :info, "Added validation logs to #{socket.assigns.log_feed_target}.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("dev-clear-log-dir", _params, socket) do
    if socket.assigns.dev_log_controls_enabled? do
      :ok = DevControls.clear_log_dir()
      {:noreply, put_flash(socket, :info, "Cleared #{socket.assigns.log_feed_target}.")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="mx-auto max-w-6xl space-y-8 p-6">
        <.header>
          BeamWatch — Incident triage
          <:subtitle>
            {count_active(@incidents)} active &bull; {count_status(@incidents, :acknowledged)} acknowledged &bull; {count_status(
              @incidents,
              :silenced
            )} silenced &bull; {count_status(@incidents, :resolved)} resolved
          </:subtitle>
        </.header>

        <.incident_list
          incidents={sorted_incidents(@incidents)}
          expanded={@expanded_incidents}
          silences={@silences}
        />

        <.silences_panel :if={map_size(@silences) > 0} silences={@silences} />

        <.source_health_panel sources={@source_health} />

        <.recent_activity_panel entries={@recent_activity} />

        <.starter_shell_panel />

        <.dev_controls_panel
          :if={@dev_log_controls_enabled?}
          target={@log_feed_target}
        />
      </section>
    </Layouts.app>
    """
  end

  # ------------------------------------------------------------------
  # Components
  # ------------------------------------------------------------------

  attr :incidents, :list, required: true
  attr :expanded, :any, required: true
  attr :silences, :map, required: true

  defp incident_list(assigns) do
    ~H"""
    <div class="space-y-3">
      <h2 class="text-lg font-semibold text-zinc-950">Incidents</h2>
      <div
        :if={@incidents == []}
        class="rounded-lg border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500"
      >
        No active incidents.
      </div>
      <div
        :for={incident <- @incidents}
        class="rounded-lg border border-zinc-200 bg-white p-4 space-y-3"
      >
        <div class="flex items-start justify-between gap-4">
          <div class="flex items-center gap-2 flex-wrap">
            <.severity_badge severity={incident.severity} />
            <.status_badge status={incident.status} />
            <span class="text-sm font-medium text-zinc-950">
              {incident_type_name(incident.type)}
            </span>
            <span class="text-sm text-zinc-600">
              {incident.resource}
            </span>
          </div>
          <div class="text-xs text-zinc-400 whitespace-nowrap">
            {format_dt(incident.first_seen)} &mdash; {format_dt(incident.last_seen)}
          </div>
        </div>

        <div class="flex items-center gap-1.5 flex-wrap">
          <.action_buttons incident={incident} silences={@silences} />
          <button
            type="button"
            phx-click="toggle-evidence"
            phx-value-id={encode_id(incident.id)}
            class="text-xs text-zinc-500 hover:text-zinc-800 underline"
          >
            {if MapSet.member?(@expanded, encode_id(incident.id)),
              do: "Hide evidence",
              else: "Show evidence (#{length(incident.evidence)})"}
          </button>
        </div>

        <div
          :if={MapSet.member?(@expanded, encode_id(incident.id))}
          class="rounded bg-zinc-50 p-3 space-y-1 max-h-64 overflow-y-auto"
        >
          <div
            :for={ev <- incident.evidence}
            class="text-xs font-mono text-zinc-700 leading-relaxed"
          >
            <span class="text-zinc-400">[{ev.source}]</span> {ev.raw}
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :silences, :map, required: true

  defp silences_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <h2 class="text-lg font-semibold text-zinc-950">Silences</h2>
      <div class="rounded-lg border border-zinc-200 bg-white p-4 space-y-2">
        <div
          :for={{_key, silence} <- @silences}
          class="flex items-center justify-between gap-4 text-sm"
        >
          <div>
            <span class="font-medium">{silence_scope_label(silence)}</span>
            <span class="text-zinc-500 ml-2">{silence_key_label(silence)}</span>
          </div>
          <button
            type="button"
            phx-click="clear-silence"
            phx-value-scope={to_string(silence.scope)}
            phx-value-key={encode_silence_key(silence)}
            class="text-xs text-red-600 hover:text-red-800 underline"
          >
            Clear
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :sources, :map, required: true

  defp source_health_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <h2 class="text-lg font-semibold text-zinc-950">Source health</h2>
      <div
        :if={@sources == %{}}
        class="rounded-lg border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500"
      >
        No sources monitored yet.
      </div>
      <div :if={@sources != %{}} class="overflow-x-auto rounded-lg border border-zinc-200 bg-white">
        <table class="table table-sm text-xs">
          <thead>
            <tr>
              <th>Source</th>
              <th>Exists</th>
              <th>Size</th>
              <th>Offset</th>
              <th>Last event</th>
              <th>Failures</th>
              <th>Rotations</th>
              <th>Truncated</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={health <- @sources |> Map.values() |> Enum.sort_by(& &1.source)}>
              <td class="font-mono">{health.source}</td>
              <td>{health.exists?}</td>
              <td>{health.size || "—"}</td>
              <td>{health.offset || "—"}</td>
              <td>{if health.last_event_at, do: format_dt(health.last_event_at), else: "—"}</td>
              <td class={if health.parse_failures > 0, do: "text-error font-semibold"}>
                {health.parse_failures}
              </td>
              <td>{health.rotations}</td>
              <td>{if health.truncated?, do: "Yes", else: "No"}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :entries, :list, required: true

  defp recent_activity_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <h2 class="text-lg font-semibold text-zinc-950">Recent activity</h2>
      <div
        :if={@entries == []}
        class="rounded-lg border border-zinc-200 bg-white p-6 text-center text-sm text-zinc-500"
      >
        No recent activity.
      </div>
      <div
        :if={@entries != []}
        class="rounded-lg border border-zinc-200 bg-white p-3 max-h-48 overflow-y-auto space-y-0.5"
      >
        <div
          :for={entry <- Enum.take(@entries, 100)}
          class="text-xs font-mono text-zinc-600 leading-relaxed"
        >
          {activity_entry(entry)}
        </div>
      </div>
    </div>
    """
  end

  defp starter_shell_panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-zinc-300 bg-white p-6">
      <h2 class="text-base font-semibold text-zinc-950">BeamWatch</h2>
      <p class="mt-2 text-sm leading-6 text-zinc-600">
        Live incident triage for Unraid-like system logs. Incidents are detected from
        log files in <code class="rounded bg-zinc-100 px-1.5 py-0.5">priv/logs/</code>.
      </p>
    </div>
    """
  end

  attr :target, :string, required: true

  defp dev_controls_panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-zinc-50 p-6">
      <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 class="text-base font-semibold text-zinc-950">Dev log controls</h2>
          <p class="mt-2 text-sm leading-6 text-zinc-600">
            Target: <code class="rounded bg-white px-1.5 py-0.5 text-zinc-800">{@target}</code>
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            phx-click="dev-add-validation-logs"
            class="rounded-md bg-zinc-950 px-3 py-2 text-sm font-semibold text-white hover:bg-zinc-800"
          >
            Add validation logs
          </button>
          <button
            type="button"
            phx-click="dev-clear-log-dir"
            class="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm font-semibold text-zinc-900 hover:bg-zinc-100"
          >
            Clear log dir
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Sub-components
  # ------------------------------------------------------------------

  attr :severity, :atom, required: true

  defp severity_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @severity == :high && "badge-error",
      @severity == :medium && "badge-warning"
    ]}>
      {@severity |> to_string() |> String.upcase()}
    </span>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @status == :active && "badge-error",
      @status == :acknowledged && "badge-info",
      @status == :silenced && "badge-ghost",
      @status == :resolved && "badge-success"
    ]}>
      {@status |> to_string() |> String.capitalize()}
    </span>
    """
  end

  attr :incident, :map, required: true
  attr :silences, :map, required: true

  defp action_buttons(assigns) do
    ~H"""
    <button
      :if={@incident.status == :active}
      type="button"
      phx-click="acknowledge"
      phx-value-id={encode_id(@incident.id)}
      class="text-xs text-zinc-600 hover:text-zinc-800 underline"
    >
      Acknowledge
    </button>
    <button
      :if={@incident.status in [:active, :acknowledged] && !@incident.silenced?}
      type="button"
      phx-click="silence-incident"
      phx-value-id={encode_id(@incident.id)}
      class="text-xs text-zinc-600 hover:text-zinc-800 underline"
    >
      Silence this
    </button>
    <button
      :if={
        @incident.status in [:active, :acknowledged] &&
          !incident_type_silenced?(@incident.type, @silences)
      }
      type="button"
      phx-click="silence-type"
      phx-value-type={@incident.type}
      class="text-xs text-zinc-600 hover:text-zinc-800 underline"
    >
      Silence type
    </button>
    <button
      :if={@incident.status in [:active, :acknowledged, :silenced]}
      type="button"
      phx-click="resolve"
      phx-value-id={encode_id(@incident.id)}
      class="text-xs text-zinc-600 hover:text-zinc-800 underline"
    >
      Resolve
    </button>
    <button
      :if={@incident.silenced?}
      type="button"
      phx-click="clear-silence"
      phx-value-scope="incident"
      phx-value-key={encode_id(@incident.id)}
      class="text-xs text-red-600 hover:text-red-800 underline"
    >
      Clear silence
    </button>
    """
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp incident_type_name(:container_restart_loop), do: "Container Restart Loop"
  defp incident_type_name(:disk_smart_warning), do: "Disk SMART Warning"
  defp incident_type_name(:share_permission_failure), do: "Share Permission Failure"
  defp incident_type_name(:vm_boot_failure), do: "VM Boot Failure"

  defp sorted_incidents(incidents) do
    incidents
    |> Map.values()
    |> Enum.sort_by(
      fn i ->
        {status_order(i.status), severity_order(i.severity),
         DateTime.to_unix(i.last_seen, :second)}
      end,
      :desc
    )
  end

  defp status_order(:active), do: 4
  defp status_order(:acknowledged), do: 3
  defp status_order(:silenced), do: 2
  defp status_order(:resolved), do: 1

  defp severity_order(:high), do: 2
  defp severity_order(:medium), do: 1

  defp incident_type_silenced?(type, silences) do
    Map.has_key?(silences, {:type, type})
  end

  defp silence_scope_label(%{scope: :incident}), do: "Incident"
  defp silence_scope_label(%{scope: :type}), do: "Type"

  defp silence_key_label(%{scope: :incident, key: {type, resource}}) do
    "#{incident_type_name(type)} — #{resource}"
  end

  defp silence_key_label(%{scope: :type, key: type}) do
    incident_type_name(type)
  end

  defp encode_id({type, resource}) do
    "#{type}:#{resource}"
  end

  defp decode_id(string) do
    [type_str, resource] = String.split(string, ":", parts: 2)
    {String.to_existing_atom(type_str), resource}
  end

  defp encode_silence_key(%{scope: :incident, key: key}), do: encode_id(key)
  defp encode_silence_key(%{scope: :type, key: key}), do: to_string(key)

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_dt(nil), do: "—"

  defp activity_entry({:event, %Event{source: source, payload: payload, timestamp: ts}}) do
    prefix = if ts, do: Calendar.strftime(ts, "%H:%M:%S"), else: "??:??:??"
    "[#{prefix}] [#{source}] #{truncate(payload, 80)}"
  end

  defp activity_entry(_), do: "Unknown activity"

  defp truncate(s, max) when byte_size(s) <= max, do: s

  defp truncate(s, max) do
    String.slice(s, 0, max - 1) <> "…"
  end

  defp count_active(incidents) do
    Enum.count(incidents, fn {_id, i} -> i.status == :active end)
  end

  defp count_status(incidents, status) do
    Enum.count(incidents, fn {_id, i} -> i.status == status end)
  end
end
