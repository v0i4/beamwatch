defmodule BeamWatch.Ingest.Parser do
  @moduledoc """
  Turns a raw log line into a `BeamWatch.Ingest.Event` or flags it as malformed.

  Lines are expected to look like `"<ISO8601 timestamp> <message>"`, e.g.

      2026-06-05T15:04:00Z container=plex event=die exit_code=137

  `key=value` pairs in the message are extracted into the event's `fields`
  map (quoted values may contain spaces). Anything that cannot be trusted is
  returned as `{:malformed, raw, reason}` so the watcher can surface it through
  source health and recent activity instead of dropping it silently or
  crashing ingestion.

  Malformed reasons:

    * `:blank` - the line was empty or whitespace only
    * `:no_timestamp` - the line did not start with a parseable ISO8601 timestamp
    * `:empty_payload` - a valid timestamp with no message after it
    * `:truncated` - a `key=` pair with a missing value (e.g. `disk=` at end of line)
  """

  alias BeamWatch.Ingest.Event

  # Matches key=value pairs, supporting quoted values that contain spaces.
  @field_regex ~r/([A-Za-z][\w.\-]*)=(?:"([^"]*)"|(\S+))/
  # Matches a key= with no following value (truncated line).
  @empty_field_regex ~r/(?:^|\s)[A-Za-z][\w.\-]*=(?:\s|$)/

  @type result :: {:ok, Event.t()} | {:malformed, String.t(), atom()}

  @doc """
  Parses a single raw log `line`.

  Options:

    * `:source` - the originating log file name (required for useful events)
    * `:ingested_at` - the time the line was read; defaults to `DateTime.utc_now/0`
  """
  @spec parse(String.t(), keyword()) :: result()
  def parse(line, opts \\ []) when is_binary(line) do
    source = Keyword.get(opts, :source, "unknown")
    ingested_at = Keyword.get(opts, :ingested_at, DateTime.utc_now())

    raw = strip_eol(line)
    trimmed = String.trim(raw)

    if trimmed == "" do
      {:malformed, raw, :blank}
    else
      parse_trimmed(trimmed, raw, source, ingested_at)
    end
  end

  defp parse_trimmed(trimmed, raw, source, ingested_at) do
    case split_timestamp(trimmed) do
      {:ok, timestamp, payload} ->
        classify(timestamp, payload, raw, source, ingested_at)

      :error ->
        {:malformed, raw, :no_timestamp}
    end
  end

  defp classify(timestamp, payload, raw, source, ingested_at) do
    cond do
      payload == "" ->
        {:malformed, raw, :empty_payload}

      Regex.match?(@empty_field_regex, payload) ->
        {:malformed, raw, :truncated}

      true ->
        {:ok,
         %Event{
           source: source,
           timestamp: timestamp,
           raw: raw,
           payload: payload,
           fields: extract_fields(payload),
           ingested_at: ingested_at
         }}
    end
  end

  defp split_timestamp(trimmed) do
    {token, rest} =
      case String.split(trimmed, " ", parts: 2) do
        [token, rest] -> {token, String.trim(rest)}
        [token] -> {token, ""}
      end

    case DateTime.from_iso8601(token) do
      {:ok, datetime, _offset} -> {:ok, datetime, rest}
      {:error, _reason} -> :error
    end
  end

  defp extract_fields(payload) do
    @field_regex
    |> Regex.scan(payload)
    |> Map.new(fn
      # Quoted value: the trailing (bare) capture group is dropped by Regex.scan.
      [_full, key, quoted] -> {key, quoted}
      [_full, key, quoted, bare] -> {key, if(quoted != "", do: quoted, else: bare)}
    end)
  end

  defp strip_eol(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end
end
