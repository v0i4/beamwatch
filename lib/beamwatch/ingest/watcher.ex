defmodule BeamWatch.Ingest.Watcher do
  @moduledoc """
  Event-driven log directory watcher.

  Uses `file_system` to watch the log directory, tails each log file from a
  remembered offset, parses new lines, and broadcasts parsed events and source
  health updates on `BeamWatch.PubSub`.

  Behaviour:

  * Existing files at startup start at EOF (tail-new).
  * New files discovered after startup start at offset 0.
  * File rotation or truncation is detected when the current size is smaller
    than the last known offset; the offset is reset to 0.
  * Incomplete lines (no trailing newline) are held back and retried on the
    next read.
  * A periodic reconcile (~2 s) re-scans tracked files and catches any
    missed changes.
  * If the watched directory is removed and recreated, the watcher re-
    establishes the inotify watch.

  Broadcasts:

    * `{:beamwatch, :event, %BeamWatch.Ingest.Event{}}` on topic
      `"beamwatch:events"`
    * `{:beamwatch, :health, %BeamWatch.Ingest.SourceHealth{}}` on topic
      `"beamwatch:health"`
  """

  use GenServer

  require Logger

  alias BeamWatch.Ingest.{Event, Parser, SourceHealth}
  alias BeamWatch.LogFeed.DevControls

  @default_reconcile_interval 2_000
  @pubsub_events "beamwatch:events"
  @pubsub_health "beamwatch:health"

  # ------------------------------------------------------------------
  # API
  # ------------------------------------------------------------------

  @doc """
  Starts the watcher.

  Options:

    * `:dir` — directory to watch (defaults to `priv/logs`)
    * `:reconcile_interval` — ms between reconcile ticks (default 2000)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Returns the current source health map.
  """
  @spec sources(GenServer.server()) :: %{String.t() => SourceHealth.t()}
  def sources(server \\ __MODULE__) do
    GenServer.call(server, :sources)
  end

  @doc """
  Forces a reconcile of all tracked files.
  """
  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(server \\ __MODULE__) do
    GenServer.cast(server, :reconcile)
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, DevControls.target_dir())
    reconcile_interval = Keyword.get(opts, :reconcile_interval, @default_reconcile_interval)

    fs_pid = start_fs(dir)
    sources = discover_files(dir)

    timer = schedule_reconcile(reconcile_interval)

    {:ok,
     %{
       dir: dir,
       fs_pid: fs_pid,
       sources: sources,
       reconcile_interval: reconcile_interval,
       reconcile_timer: timer
     }}
  end

  @impl true
  def handle_call(:sources, _from, state) do
    {:reply, state.sources, state}
  end

  @impl true
  def handle_cast(:reconcile, state) do
    state = do_reconcile(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, events}}, state) do
    source = Path.basename(path)
    health = Map.get(state.sources, source, SourceHealth.new(source))
    %SourceHealth{} = health

    # If the file was removed, mark it missing.
    health =
      if :removed in events do
        %SourceHealth{health | exists?: false, size: nil, truncated?: false}
      else
        health
      end

    # If this is a newly-seen file, start from the beginning.
    is_new = not Map.has_key?(state.sources, source)
    health = if is_new, do: %SourceHealth{health | offset: 0}, else: health

    # Read and parse unless the file was just removed.
    sources =
      if :removed in events do
        Map.put(state.sources, source, health)
      else
        {_events, new_health} = process_file(source, path, health)
        Map.put(state.sources, source, new_health)
      end

    {:noreply, %{state | sources: sources}}
  end

  @impl true
  def handle_info({:file_event, _pid, :stop}, state) do
    # FileSystem watcher died (directory removed, etc.).
    fs_pid = start_fs(state.dir)
    {:noreply, %{state | fs_pid: fs_pid}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state = do_reconcile(state)
    timer = schedule_reconcile(state.reconcile_interval)
    {:noreply, %{state | reconcile_timer: timer}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Watcher unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp start_fs(dir) do
    if File.dir?(dir) do
      {:ok, pid} = FileSystem.start_link(dirs: [dir], backend: :fs_inotify)
      FileSystem.subscribe(pid)
      pid
    else
      nil
    end
  end

  defp schedule_reconcile(interval) do
    Process.send_after(self(), :reconcile, interval)
  end

  defp discover_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.basename/1)
        |> Enum.reduce(%{}, fn source, acc ->
          path = Path.join(dir, source)
          discover_file(path, source, acc)
        end)

      {:error, _} ->
        %{}
    end
  end

  defp discover_file(path, source, acc) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        health = %SourceHealth{
          source: source,
          exists?: true,
          size: size,
          offset: size,
          last_read_at: DateTime.utc_now(),
          parse_failures: 0,
          malformed_samples: [],
          rotations: 0,
          truncated?: false
        }

        Map.put(acc, source, health)

      {:error, _} ->
        acc
    end
  end

  defp do_reconcile(state) do
    state = ensure_fs_pid(state)
    sources = reconcile_tracked_sources(state)
    sources = discover_new_sources(state, sources)
    %{state | sources: sources}
  end

  defp ensure_fs_pid(state) do
    fs_pid =
      if state.fs_pid == nil and File.dir?(state.dir) do
        start_fs(state.dir)
      else
        state.fs_pid
      end

    %{state | fs_pid: fs_pid}
  end

  defp reconcile_tracked_sources(state) do
    Enum.reduce(state.sources, state.sources, fn {source, health}, acc ->
      path = Path.join(state.dir, source)
      {_, new_health} = process_file(source, path, health)
      Map.put(acc, source, new_health)
    end)
  end

  defp discover_new_sources(state, sources) do
    case File.ls(state.dir) do
      {:ok, files} ->
        Enum.reduce(files, sources, fn file, acc ->
          source = file
          path = Path.join(state.dir, source)
          try_discover_new_source(path, source, acc)
        end)

      {:error, _} ->
        sources
    end
  end

  defp try_discover_new_source(path, source, acc) do
    if File.regular?(path) and not Map.has_key?(acc, source) do
      health = %SourceHealth{SourceHealth.new(source) | exists?: true, offset: 0}
      {_, new_health} = process_file(source, path, health)
      Map.put(acc, source, new_health)
    else
      acc
    end
  end

  defp process_file(source, path, health) do
    ingested_at = DateTime.utc_now()
    {results, new_offset, meta} = read_and_parse(path, health, source, ingested_at)

    {events, malformed_count, malformed_samples} = classify_results(results, health)
    events = Enum.reverse(events)

    result = %{
      new_offset: new_offset,
      events: events,
      malformed_count: malformed_count,
      malformed_samples: malformed_samples,
      meta: meta
    }

    new_health = build_health(source, path, health, ingested_at, result)

    broadcast_results(events, new_health)
    {events, new_health}
  end

  defp classify_results(results, health) do
    Enum.reduce(results, {[], 0, health.malformed_samples}, fn
      {:ok, event}, {evs, count, samples} ->
        {[event | evs], count, samples}

      {:malformed, raw, _reason}, {evs, count, samples} ->
        new_samples =
          if length(samples) < 3 do
            [raw | samples]
          else
            samples
          end

        {evs, count + 1, new_samples}
    end)
  end

  defp build_health(source, path, health, ingested_at, result) do
    exists? = File.exists?(path)

    size =
      case File.stat(path) do
        {:ok, %{size: s}} -> s
        {:error, _} -> health.size
      end

    last_event_at =
      case result.events do
        [] -> health.last_event_at
        [first | _] -> Event.at(first) || ingested_at
      end

    %SourceHealth{malformed_samples: _, parse_failures: _, rotations: _} = health

    %SourceHealth{
      health
      | source: source,
        exists?: exists?,
        size: size,
        offset: result.new_offset,
        last_read_at: ingested_at,
        last_event_at: last_event_at,
        parse_failures: health.parse_failures + result.malformed_count,
        malformed_samples: result.malformed_samples,
        rotations: if(result.meta == :rotated, do: health.rotations + 1, else: health.rotations),
        truncated?: result.meta == :rotated
    }
  end

  defp broadcast_results(events, new_health) do
    Enum.each(events, fn event ->
      Phoenix.PubSub.broadcast(BeamWatch.PubSub, @pubsub_events, {:beamwatch, :event, event})
    end)

    Phoenix.PubSub.broadcast(
      BeamWatch.PubSub,
      @pubsub_health,
      {:beamwatch, :health, new_health}
    )
  end

  # Reads new bytes from `path` starting at `health.offset`, parses them, and
  # returns `{parse_results, new_offset, meta}` where `meta` is `:rotated`,
  # `:unchanged`, `:missing`, or `:new_lines`.
  defp read_and_parse(path, health, source, ingested_at) do
    current_offset = health.offset || 0

    case File.stat(path) do
      {:ok, %{size: size}} when size < current_offset ->
        data = read_all(path)
        {results, processed} = parse_chunk(data, source, ingested_at)
        {results, processed, :rotated}

      {:ok, %{size: size}} when size == current_offset ->
        {[], current_offset, :unchanged}

      {:ok, %{size: size}} ->
        data = read_file_range(path, current_offset, size - current_offset)
        {results, processed} = parse_chunk(data, source, ingested_at)
        {results, current_offset + processed, :new_lines}

      {:error, _} ->
        {[], current_offset, :missing}
    end
  end

  defp read_file_range(path, offset, bytes_to_read) do
    {:ok, fd} = :file.open(path, [:read, :binary, :raw])
    {:ok, _} = :file.position(fd, offset)
    {:ok, data} = :file.read(fd, bytes_to_read)
    :ok = :file.close(fd)
    data
  end

  defp read_all(path) do
    case File.read(path) do
      {:ok, data} -> data
      {:error, _} -> ""
    end
  end

  defp parse_chunk(data, source, ingested_at) do
    if data == "" do
      {[], 0}
    else
      parts = String.split(data, "\n", trim: false)
      {lines, processed_bytes} = split_lines(data, parts)

      results = Enum.map(lines, &Parser.parse(&1, source: source, ingested_at: ingested_at))
      {results, processed_bytes}
    end
  end

  defp split_lines(data, parts) do
    if String.ends_with?(data, "\n") do
      lines = Enum.reject(parts, &(&1 == ""))
      {lines, byte_size(data)}
    else
      split_incomplete(data, parts)
    end
  end

  defp split_incomplete(data, parts) do
    if length(parts) == 1 do
      {[], 0}
    else
      complete_parts = Enum.take(parts, length(parts) - 1)
      lines = Enum.reject(complete_parts, &(&1 == ""))
      last = List.last(parts)
      processed = byte_size(data) - byte_size(last)
      {lines, processed}
    end
  end
end
