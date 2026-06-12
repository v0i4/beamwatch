defmodule BeamWatch.Incidents.Engine do
  @moduledoc """
  Central incident engine — GenServer that holds all incident state,
  processes incoming log events through detectors, and broadcasts
  state updates over PubSub.

  Data flow:

    Watcher -> PubSub("beamwatch:events") -> Engine -> PubSub("beamwatch:state") -> LiveView

  The engine is the single in-memory source of truth (no database). It
  maintains incidents, silences, a bounded recent-activity buffer, and
  per-detector scratch space.

  ## Public API

      Engine.snapshot/0      — returns the current full state
      Engine.acknowledge/1  — mark an incident acknowledged
      Engine.silence/2      — silence an incident or incident type
      Engine.resolve/1      — resolve an incident
      Engine.clear_silence/1 — remove a silence
  """

  use GenServer, restart: :permanent

  require Logger

  alias BeamWatch.Incidents.Detectors.ContainerRestartLoop
  alias BeamWatch.Incidents.Detectors.DiskSmartWarning
  alias BeamWatch.Incidents.Detectors.SharePermissionFailure
  alias BeamWatch.Incidents.Detectors.VMBootFailure
  alias BeamWatch.Incidents.{Incident, Silence}

  @pubsub BeamWatch.PubSub
  @topic_events "beamwatch:events"
  @topic_updates "beamwatch:state"
  @max_recent_activity 200
  @detectors [ContainerRestartLoop, DiskSmartWarning, SharePermissionFailure, VMBootFailure]

  # ------------------------------------------------------------------
  # API
  # ------------------------------------------------------------------

  @doc """
  Starts the engine.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the full engine snapshot: incidents, silences, recent activity,
  and detector scratch space.
  """
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc """
  Marks the incident identified by `{type, resource}` as acknowledged.
  """
  @spec acknowledge(GenServer.server(), Incident.id()) :: :ok
  def acknowledge(server \\ __MODULE__, incident_id) do
    GenServer.cast(server, {:acknowledge, incident_id})
  end

  @doc """
  Silences the given scope/key.
  `scope` is `:incident` (targets a specific incident) or `:type`
  (silences all incidents of that type). `key` is the incident id
  or type atom.
  """
  @spec silence(GenServer.server(), Silence.scope(), term()) :: :ok
  def silence(server \\ __MODULE__, scope, key) do
    GenServer.cast(server, {:silence, scope, key})
  end

  @doc """
  Resolves an incident by id.
  """
  @spec resolve(GenServer.server(), Incident.id()) :: :ok
  def resolve(server \\ __MODULE__, incident_id) do
    GenServer.cast(server, {:resolve, incident_id})
  end

  @doc """
  Removes a silence by scope and key.
  """
  @spec clear_silence(GenServer.server(), Silence.scope(), term()) :: :ok
  def clear_silence(server \\ __MODULE__, scope, key) do
    GenServer.cast(server, {:clear_silence, scope, key})
  end

  # ------------------------------------------------------------------
  # Callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    pubsub = Keyword.get(opts, :pubsub, @pubsub)
    :ok = Phoenix.PubSub.subscribe(pubsub, @topic_events)

    state = %{
      incidents: %{},
      silences: %{},
      recent_activity: [],
      detector_scratch: %{},
      pubsub: pubsub
    }

    broadcast_update(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:beamwatch, :event, event}, state) do
    state = push_activity(state, {:event, event})
    state = apply_detectors(state, event)
    broadcast_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Engine unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:acknowledge, incident_id}, state) do
    case Map.get(state.incidents, incident_id) do
      nil ->
        Logger.warning("Engine: acknowledge for unknown incident #{inspect(incident_id)}")
        {:noreply, state}

      incident ->
        updated = %{incident | status: :acknowledged}
        state = put_incident(state, updated)
        broadcast_update(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:silence, scope, key}, state) do
    silence = Silence.new(scope, key)
    silences = Map.put(state.silences, {scope, key}, silence)
    state = %{state | silences: silences}

    # If silencing a specific incident, update its silenced? flag.
    state =
      if scope == :incident do
        case Map.get(state.incidents, key) do
          nil -> state
          incident -> put_incident(state, %{incident | silenced?: true})
        end
      else
        state
      end

    broadcast_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:resolve, incident_id}, state) do
    case Map.get(state.incidents, incident_id) do
      nil ->
        Logger.warning("Engine: resolve for unknown incident #{inspect(incident_id)}")
        {:noreply, state}

      incident ->
        updated = %{incident | status: :resolved}
        state = put_incident(state, updated)
        broadcast_update(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:clear_silence, scope, key}, state) do
    silences = Map.delete(state.silences, {scope, key})
    state = %{state | silences: silences}

    # If clearing an incident silence, restore its silenced? flag.
    state =
      if scope == :incident do
        case Map.get(state.incidents, key) do
          nil -> state
          incident -> put_incident(state, %{incident | silenced?: false})
        end
      else
        state
      end

    broadcast_update(state)
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Private
  # ------------------------------------------------------------------

  defp push_activity(state, entry) do
    recent = [entry | state.recent_activity] |> Enum.take(@max_recent_activity)
    %{state | recent_activity: recent}
  end

  defp put_incident(state, incident) do
    %{state | incidents: Map.put(state.incidents, incident.id, incident)}
  end

  defp apply_detectors(state, event) do
    Enum.reduce(@detectors, state, fn detector, acc ->
      detector.detect(acc, event)
    end)
  end

  defp broadcast_update(state) do
    Phoenix.PubSub.broadcast(state.pubsub, @topic_updates, {:beamwatch, :updated})
  end
end
