defmodule BeamWatch.Ingest.Event do
  @moduledoc """
  A single parsed log line.

  An event carries the originating log file (`source`), the raw line as read
  from disk (`raw`), the message with the leading timestamp stripped
  (`payload`), the embedded log `timestamp` when one was present, the
  `key=value` pairs extracted from the payload (`fields`), and the time the
  line was read by the watcher (`ingested_at`).

  Detection works off `at/1`, which prefers the embedded log timestamp and
  falls back to ingestion time when a line has no parseable timestamp.
  """

  @enforce_keys [:source, :raw]
  defstruct [:source, :timestamp, :raw, :payload, :ingested_at, fields: %{}]

  @type t :: %__MODULE__{
          source: String.t(),
          timestamp: DateTime.t() | nil,
          raw: String.t(),
          payload: String.t() | nil,
          fields: %{optional(String.t()) => String.t()},
          ingested_at: DateTime.t() | nil
        }

  @doc """
  Returns the best-known time for an event.

  Prefers the timestamp embedded in the log line and falls back to the
  ingestion time when the line carried no parseable timestamp.
  """
  @spec at(t()) :: DateTime.t() | nil
  def at(%__MODULE__{timestamp: %DateTime{} = timestamp}), do: timestamp
  def at(%__MODULE__{ingested_at: ingested_at}), do: ingested_at

  @doc """
  Fetches a parsed `key=value` field by key, returning `nil` when absent.
  """
  @spec field(t(), String.t()) :: String.t() | nil
  def field(%__MODULE__{fields: fields}, key), do: Map.get(fields, key)
end
