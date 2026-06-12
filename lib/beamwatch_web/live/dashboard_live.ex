defmodule BeamWatchWeb.DashboardLive do
  use BeamWatchWeb, :live_view

  alias BeamWatch.Incidents.Engine
  alias BeamWatch.Ingest.Event
  alias BeamWatch.LogFeed.DevControls

  @topic_state "beamwatch:state"
  @topic_health "beamwatch:health"

  @source_labels %{
    "docker.log" => "Container",
    "syslog.log" => "System",
    "smb.log" => "SMB",
    "nfs.log" => "NFS",
    "nginx.log" => "Nginx",
    "app.log" => "App",
    "libvirt.log" => "Libvirt",
    "qemu.log" => "QEMU",
    "unraid-dev.log" => "Dev"
  }

  @source_classes %{
    "docker.log" => "bg-blue-100 text-blue-800",
    "syslog.log" => "bg-yellow-100 text-yellow-800",
    "smb.log" => "bg-purple-100 text-purple-800",
    "nfs.log" => "bg-purple-100 text-purple-800",
    "nginx.log" => "bg-green-100 text-green-800",
    "app.log" => "bg-indigo-100 text-indigo-800",
    "libvirt.log" => "bg-red-100 text-red-800",
    "qemu.log" => "bg-red-100 text-red-800",
    "unraid-dev.log" => "bg-gray-100 text-gray-800"
  }

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
       log_feed_target: Path.relative_to_cwd(DevControls.target_dir()),
       filters: %{status: [], severity: [], type: []},
       selected_incident_id: nil
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

  def handle_event("filter-changed", %{"filter" => params}, socket) do
    filters = %{
      status: parse_filter_list(params["status"]),
      severity: parse_filter_list(params["severity"]),
      type: parse_filter_list(params["type"])
    }

    {:noreply, assign(socket, filters: filters)}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply, assign(socket, filters: %{status: [], severity: [], type: []})}
  end

  def handle_event("select-incident", %{"id" => id}, socket) do
    selected_id = if socket.assigns.selected_incident_id == id, do: nil, else: id
    {:noreply, assign(socket, selected_incident_id: selected_id)}
  end

  def handle_event("bulk-action", %{"action" => action}, socket) do
    selected = get_filtered_incidents(socket.assigns.incidents, socket.assigns.filters)

    Enum.each(selected, fn incident ->
      case action do
        "acknowledge" -> Engine.acknowledge(incident.id)
        "resolve" -> Engine.resolve(incident.id)
        "silence" -> Engine.silence(:incident, incident.id)
        "silence-type" -> Engine.silence(:type, incident.type)
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex h-screen bg-gray-50">
        <!-- Sidebar Filters -->
        <aside class="w-64 bg-white border-r border-gray-200 p-4 flex-shrink-0">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Filters</h2>
          <.filter_panel filters={@filters} />
          <.quick_actions_panel incidents={@incidents} filters={@filters} />
        </aside>
        
    <!-- Main Content -->
        <main class="flex-1 overflow-auto p-6">
          <header class="mb-6">
            <div class="flex items-center justify-between">
              <div>
                <h1 class="text-2xl font-bold text-gray-900">BeamWatch — Incident Triage</h1>
                <p class="text-sm text-gray-500 mt-1">
                  {count_active(@incidents)} active &bull; {count_status(@incidents, :acknowledged)} acknowledged &bull; {count_status(
                    @incidents,
                    :silenced
                  )} silenced &bull; {count_status(@incidents, :resolved)} resolved
                </p>
              </div>
              <div class="flex items-center gap-3">
                <span class="text-xs text-gray-500">Keyboard shortcuts: <kbd>?</kbd></span>
                <button
                  :if={has_active_filters?(@filters)}
                  phx-click="clear-filters"
                  class="px-3 py-1.5 text-xs font-medium text-gray-600 bg-gray-100 rounded-md hover:bg-gray-200"
                >
                  Clear all filters
                </button>
              </div>
            </div>
          </header>

          <.incident_list
            incidents={get_filtered_incidents(@incidents, @filters)}
            expanded={@expanded_incidents}
            silences={@silences}
            selected_incident_id={@selected_incident_id}
          />

          <.silences_panel :if={map_size(@silences) > 0} silences={@silences} />

          <.source_health_panel sources={@source_health} />

          <.recent_activity_panel entries={@recent_activity} />

          <.starter_shell_panel />

          <.dev_controls_panel
            :if={@dev_log_controls_enabled?}
            target={@log_feed_target}
          />
        </main>
      </div>
    </Layouts.app>
    """
  end

  # ------------------------------------------------------------------
  # Filter Panel
  # ------------------------------------------------------------------

  attr :filters, :map, required: true

  defp filter_panel(assigns) do
    ~H"""
    <div class="space-y-6 mb-6">
      <.form for={%{}} phx-change="filter-changed" class="space-y-6">
        <!-- Status Filter -->
        <div>
          <h3 class="text-sm font-medium text-gray-700 mb-2">Status</h3>
          <div class="space-y-1">
            <label
              :for={status <- [:active, :acknowledged, :silenced, :resolved]}
              class="flex items-center gap-2 cursor-pointer"
            >
              <input
                type="checkbox"
                name="filter[status][]"
                value={status}
                checked={status in @filters.status}
                class="rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
              />
              <span class="text-sm text-gray-600">
                {status |> to_string() |> String.capitalize()}
              </span>
            </label>
          </div>
        </div>
        
    <!-- Severity Filter -->
        <div>
          <h3 class="text-sm font-medium text-gray-700 mb-2">Severity</h3>
          <div class="space-y-1">
            <label :for={severity <- [:high, :medium]} class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="filter[severity][]"
                value={severity}
                checked={severity in @filters.severity}
                class="rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
              />
              <span class="text-sm text-gray-600">{severity |> to_string() |> String.upcase()}</span>
            </label>
          </div>
        </div>
        
    <!-- Type Filter -->
        <div>
          <h3 class="text-sm font-medium text-gray-700 mb-2">Incident Type</h3>
          <div class="space-y-1">
            <label :for={type <- incident_types()} class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="filter[type][]"
                value={type}
                checked={type in @filters.type}
                class="rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
              />
              <span class="text-sm text-gray-600">{incident_type_name(type)}</span>
            </label>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Quick Actions Panel
  # ------------------------------------------------------------------

  attr :incidents, :map, required: true
  attr :filters, :map, required: true

  defp quick_actions_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <h3 class="text-sm font-medium text-gray-700">Quick Actions</h3>
      <div class="space-y-2">
        <button
          phx-click="bulk-action"
          phx-value-action="acknowledge"
          class="w-full px-3 py-2 text-sm font-medium text-gray-700 bg-gray-100 rounded-md hover:bg-gray-200"
        >
          Acknowledge All Visible
        </button>
        <button
          phx-click="bulk-action"
          phx-value-action="resolve"
          class="w-full px-3 py-2 text-sm font-medium text-gray-700 bg-gray-100 rounded-md hover:bg-gray-200"
        >
          Resolve All Visible
        </button>
        <button
          phx-click="bulk-action"
          phx-value-action="silence-type"
          class="w-full px-3 py-2 text-sm font-medium text-gray-700 bg-gray-100 rounded-md hover:bg-gray-200"
        >
          Silence All Types Visible
        </button>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Incident List (Enhanced)
  # ------------------------------------------------------------------

  attr :incidents, :list, required: true
  attr :expanded, :any, required: true
  attr :silences, :map, required: true
  attr :selected_incident_id, :string, default: nil

  defp incident_list(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Incidents by Type -->
      <div :for={type <- incident_types()}>
        <div :if={has_incidents_of_type?(@incidents, type)}>
          <.incident_type_section
            type={type}
            incidents={filter_by_type(@incidents, type)}
            expanded={@expanded}
            silences={@silences}
            selected_incident_id={@selected_incident_id}
          />
        </div>
      </div>

      <div
        :if={@incidents == []}
        class="rounded-lg border border-gray-200 bg-white p-6 text-center text-sm text-gray-500"
      >
        No incidents matching your filters.
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Incident Type Section (Collapsible)
  # ------------------------------------------------------------------

  attr :type, :atom, required: true
  attr :incidents, :list, required: true
  attr :expanded, :any, required: true
  attr :silences, :map, required: true
  attr :selected_incident_id, :string, default: nil

  defp incident_type_section(assigns) do
    ~H"""
    <div class="mb-6">
      <div class="flex items-center gap-3 mb-3">
        <h3 class="text-lg font-semibold text-gray-900">{incident_type_name(@type)}</h3>
        <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-800">
          {length(@incidents)} incidents
        </span>
        <span
          :if={has_active_incidents?(@incidents)}
          class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800"
        >
          {count_active_in_type(@incidents)} active
        </span>
      </div>
      <div class="space-y-3">
        <.incident_card
          :for={incident <- @incidents}
          incident={incident}
          expanded={@expanded}
          silences={@silences}
          selected={incident.id == @selected_incident_id}
        />
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Incident Card (Individual)
  # ------------------------------------------------------------------

  attr :incident, :map, required: true
  attr :expanded, :any, required: true
  attr :silences, :map, required: true
  attr :selected, :boolean, default: false

  defp incident_card(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border bg-white p-4 space-y-3 transition-all duration-200",
      @selected && "ring-2 ring-indigo-500 ring-offset-2",
      !@selected && "border-gray-200 hover:border-gray-300"
    ]}>
      <div class="flex items-start justify-between gap-4">
        <div class="flex items-center gap-2 flex-wrap">
          <.severity_badge severity={@incident.severity} />
          <.status_badge status={@incident.status} />
          <span class="text-sm font-medium text-gray-900">
            {incident_type_name(@incident.type)}
          </span>
          <span class="text-sm text-gray-600">
            {@incident.resource}
          </span>
        </div>
        <div class="text-xs text-gray-400 whitespace-nowrap">
          {format_dt(@incident.first_seen)} &mdash; {format_dt(@incident.last_seen)}
        </div>
      </div>

      <div class="flex items-center gap-2 flex-wrap">
        <.action_buttons incident={@incident} silences={@silences} />
        <button
          type="button"
          phx-click="toggle-evidence"
          phx-value-id={encode_id(@incident.id)}
          class="px-2 py-1 text-xs text-gray-500 hover:text-gray-800 hover:bg-gray-100 rounded"
        >
          {if MapSet.member?(@expanded, encode_id(@incident.id)),
            do: "Hide evidence",
            else: "Show evidence (#{length(@incident.evidence)})"}
        </button>
      </div>

      <div
        :if={MapSet.member?(@expanded, encode_id(@incident.id))}
        class="rounded bg-gray-50 p-3 space-y-1 max-h-64 overflow-y-auto border border-gray-100"
      >
        <div
          :for={ev <- @incident.evidence}
          class="text-xs font-mono text-gray-700 leading-relaxed"
        >
          <span class="text-gray-400">[{ev.source}]</span> {ev.raw}
        </div>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Silences Panel
  # ------------------------------------------------------------------

  attr :silences, :map, required: true

  defp silences_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <h2 class="text-lg font-semibold text-gray-900">Active Silences</h2>
      <div class="rounded-lg border border-gray-200 bg-white p-4 space-y-2">
        <div
          :for={{_key, silence} <- @silences}
          class="flex items-center justify-between gap-4 text-sm"
        >
          <div class="flex items-center gap-2">
            <.silence_scope_badge scope={silence.scope} />
            <span class="text-gray-600">{silence_key_label(silence)}</span>
          </div>
          <button
            type="button"
            phx-click="clear-silence"
            phx-value-scope={to_string(silence.scope)}
            phx-value-key={encode_silence_key(silence)}
            class="px-2 py-1 text-xs font-medium text-red-600 hover:text-red-800 hover:bg-red-50 rounded"
          >
            Clear
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Source Health Panel (Enhanced)
  # ------------------------------------------------------------------

  attr :sources, :map, required: true

  defp source_health_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <h2 class="text-lg font-semibold text-gray-900">Source Health</h2>
      <div
        :if={@sources == %{}}
        class="rounded-lg border border-gray-200 bg-white p-6 text-center text-sm text-gray-500"
      >
        No sources monitored yet.
      </div>
      <div :if={@sources != %{}} class="overflow-x-auto rounded-lg border border-gray-200 bg-white">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Source
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Status
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Size
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Offset
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Last Event
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Failures
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Rotations
              </th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <tr :for={health <- @sources |> Map.values() |> Enum.sort_by(& &1.source)}>
              <td class="px-4 py-3 text-sm font-mono text-gray-900">{health.source}</td>
              <td class="px-4 py-3">
                <.health_status_badge exists={health.exists?} />
              </td>
              <td class="px-4 py-3 text-sm text-gray-900">{health.size || "—"}</td>
              <td class="px-4 py-3 text-sm text-gray-900">{health.offset || "—"}</td>
              <td class="px-4 py-3 text-sm text-gray-900">
                {if health.last_event_at, do: format_dt(health.last_event_at), else: "—"}
              </td>
              <td class="px-4 py-3">
                <span
                  :if={health.parse_failures > 0}
                  class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800"
                >
                  {health.parse_failures}
                </span>
                <span :if={health.parse_failures == 0} class="text-sm text-gray-500">0</span>
              </td>
              <td class="px-4 py-3">
                <span
                  :if={health.rotations > 0}
                  class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800"
                >
                  {health.rotations}
                </span>
                <span :if={health.rotations == 0} class="text-sm text-gray-500">0</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Recent Activity Panel (Enhanced)
  # ------------------------------------------------------------------

  attr :entries, :list, required: true

  defp recent_activity_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <h2 class="text-lg font-semibold text-gray-900">Recent Activity</h2>
      <div
        :if={@entries == []}
        class="rounded-lg border border-gray-200 bg-white p-6 text-center text-sm text-gray-500"
      >
        No recent activity.
      </div>
      <div
        :if={@entries != []}
        class="rounded-lg border border-gray-200 bg-white p-4 space-y-1"
      >
        <div
          :for={entry <- Enum.take(@entries, 50)}
          class="flex items-start gap-3 text-sm"
        >
          <span class="text-gray-400 font-mono text-xs mt-0.5">{activity_timestamp(entry)}</span>
          <span class={[
            "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
            activity_type_class(entry)
          ]}>
            {activity_type_label(entry)}
          </span>
          <span class="text-gray-700 flex-1">{activity_entry(entry)}</span>
        </div>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Starter Shell Panel
  # ------------------------------------------------------------------

  defp starter_shell_panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-gray-300 bg-white p-6">
      <h2 class="text-base font-semibold text-gray-900">BeamWatch</h2>
      <p class="mt-2 text-sm leading-6 text-gray-600">
        Live incident triage for Unraid-like system logs. Incidents are detected from
        log files in <code class="rounded bg-gray-100 px-1.5 py-0.5">priv/logs/</code>.
      </p>
      <div class="mt-4 flex items-center gap-4 text-xs text-gray-500">
        <span>
          Press <kbd class="px-1.5 py-0.5 bg-gray-100 rounded border border-gray-200">?</kbd>
          for keyboard shortcuts
        </span>
        <span>|</span>
        <span>Incidents update in real-time</span>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Dev Controls Panel
  # ------------------------------------------------------------------

  attr :target, :string, required: true

  defp dev_controls_panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-gray-200 bg-gray-50 p-6">
      <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 class="text-base font-semibold text-gray-900">Dev log controls</h2>
          <p class="mt-2 text-sm leading-6 text-gray-600">
            Target: <code class="rounded bg-white px-1.5 py-0.5 text-gray-800">{@target}</code>
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            phx-click="dev-add-validation-logs"
            class="rounded-md bg-gray-950 px-3 py-2 text-sm font-semibold text-white hover:bg-gray-800"
          >
            Add validation logs
          </button>
          <button
            type="button"
            phx-click="dev-clear-log-dir"
            class="rounded-md border border-gray-300 bg-white px-3 py-2 text-sm font-semibold text-gray-900 hover:bg-gray-100"
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
      "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
      @severity == :high && "bg-red-100 text-red-800",
      @severity == :medium && "bg-yellow-100 text-yellow-800"
    ]}>
      {@severity |> to_string() |> String.upcase()}
    </span>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
      @status == :active && "bg-red-100 text-red-800",
      @status == :acknowledged && "bg-blue-100 text-blue-800",
      @status == :silenced && "bg-gray-100 text-gray-800",
      @status == :resolved && "bg-green-100 text-green-800"
    ]}>
      {@status |> to_string() |> String.capitalize()}
    </span>
    """
  end

  attr :scope, :atom, required: true

  defp silence_scope_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
      @scope == :incident && "bg-purple-100 text-purple-800",
      @scope == :type && "bg-indigo-100 text-indigo-800"
    ]}>
      {@scope |> to_string() |> String.capitalize()}
    </span>
    """
  end

  attr :exists, :boolean, required: true

  defp health_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
      @exists && "bg-green-100 text-green-800",
      !@exists && "bg-gray-100 text-gray-800"
    ]}>
      {if @exists, do: "Active", else: "Missing"}
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
      class="px-2 py-1 text-xs font-medium text-blue-600 hover:text-blue-800 hover:bg-blue-50 rounded"
    >
      Acknowledge
    </button>
    <button
      :if={@incident.status in [:active, :acknowledged] && !@incident.silenced?}
      type="button"
      phx-click="silence-incident"
      phx-value-id={encode_id(@incident.id)}
      class="px-2 py-1 text-xs font-medium text-gray-600 hover:text-gray-800 hover:bg-gray-100 rounded"
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
      class="px-2 py-1 text-xs font-medium text-gray-600 hover:text-gray-800 hover:bg-gray-100 rounded"
    >
      Silence type
    </button>
    <button
      :if={@incident.status in [:active, :acknowledged, :silenced]}
      type="button"
      phx-click="resolve"
      phx-value-id={encode_id(@incident.id)}
      class="px-2 py-1 text-xs font-medium text-green-600 hover:text-green-800 hover:bg-green-50 rounded"
    >
      Resolve
    </button>
    <button
      :if={@incident.silenced?}
      type="button"
      phx-click="clear-silence"
      phx-value-scope="incident"
      phx-value-key={encode_id(@incident.id)}
      class="px-2 py-1 text-xs font-medium text-red-600 hover:text-red-800 hover:bg-red-50 rounded"
    >
      Clear silence
    </button>
    """
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp incident_types,
    do: [
      :container_restart_loop,
      :disk_smart_warning,
      :share_permission_failure,
      :vm_boot_failure
    ]

  defp incident_type_name(:container_restart_loop), do: "Container Restart Loop"
  defp incident_type_name(:disk_smart_warning), do: "Disk SMART Warning"
  defp incident_type_name(:share_permission_failure), do: "Share Permission Failure"
  defp incident_type_name(:vm_boot_failure), do: "VM Boot Failure"

  defp has_incidents_of_type?(incidents, type) do
    Enum.any?(incidents, fn i -> i.type == type end)
  end

  defp filter_by_type(incidents, type) do
    Enum.filter(incidents, fn i -> i.type == type end)
  end

  defp has_active_incidents?(incidents) do
    Enum.any?(incidents, fn i -> i.status == :active end)
  end

  defp count_active_in_type(incidents) do
    Enum.count(incidents, fn i -> i.status == :active end)
  end

  defp parse_filter_list(nil), do: []
  defp parse_filter_list([]), do: []

  defp parse_filter_list(values) when is_list(values) do
    Enum.map(values, fn
      v when v in ["active", "acknowledged", "silenced", "resolved"] -> String.to_existing_atom(v)
      v when v in ["high", "medium"] -> String.to_existing_atom(v)
      v -> String.to_existing_atom(v)
    end)
  end

  defp get_filtered_incidents(incidents, filters) do
    incidents
    |> Map.values()
    |> filter_by_status(filters.status)
    |> filter_by_severity(filters.severity)
    |> filter_by_type_list(filters.type)
    |> sort_incidents()
  end

  defp filter_by_status(incidents, []), do: incidents

  defp filter_by_status(incidents, statuses),
    do: Enum.filter(incidents, fn i -> i.status in statuses end)

  defp filter_by_severity(incidents, []), do: incidents

  defp filter_by_severity(incidents, severities),
    do: Enum.filter(incidents, fn i -> i.severity in severities end)

  defp filter_by_type_list(incidents, []), do: incidents

  defp filter_by_type_list(incidents, types),
    do: Enum.filter(incidents, fn i -> i.type in types end)

  defp sort_incidents(incidents) do
    Enum.sort_by(
      incidents,
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

  defp has_active_filters?(filters) do
    filters.status != [] or filters.severity != [] or filters.type != []
  end

  defp incident_type_silenced?(type, silences) do
    Map.has_key?(silences, {:type, type})
  end

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

  defp activity_timestamp({:event, %Event{timestamp: ts}}) do
    if ts, do: Calendar.strftime(ts, "%H:%M:%S"), else: "??:??:??"
  end

  defp activity_timestamp(_), do: "??:??:??"

  defp activity_type_label({:event, %Event{source: source}}) do
    @source_labels[source] || "Log"
  end

  defp activity_type_label(_), do: "Unknown"

  defp activity_type_class({:event, %Event{source: source}}) do
    @source_classes[source] || "bg-gray-100 text-gray-800"
  end

  defp activity_type_class(_), do: "bg-gray-100 text-gray-800"

  defp activity_entry({:event, %Event{source: source, payload: payload}}) do
    "[#{source}] #{truncate(payload, 80)}"
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
