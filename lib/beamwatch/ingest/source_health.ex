defmodule BeamWatch.Ingest.SourceHealth do
  @moduledoc """
  Ingestion health for a single watched log file.

  Tracks per-source metadata: whether the file exists, its current size on
  disk, the last-read byte offset, the last time we read it, the last time we
  saw a valid event, how many parse failures have occurred, recent malformed
  samples, how many rotations have been detected, and whether the file was
  truncated.
  """

  defstruct [
    :source,
    :exists?,
    :size,
    :offset,
    :last_read_at,
    :last_event_at,
    :parse_failures,
    :malformed_samples,
    :rotations,
    :truncated?
  ]

  @type t :: %__MODULE__{
          source: String.t(),
          exists?: boolean() | nil,
          size: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          last_read_at: DateTime.t() | nil,
          last_event_at: DateTime.t() | nil,
          parse_failures: non_neg_integer(),
          malformed_samples: [String.t()],
          rotations: non_neg_integer(),
          truncated?: boolean()
        }

  @doc """
  Creates a fresh health record for a given source file name.
  """
  @spec new(String.t()) :: t()
  def new(source) do
    %__MODULE__{
      source: source,
      exists?: false,
      size: nil,
      offset: nil,
      last_read_at: nil,
      last_event_at: nil,
      parse_failures: 0,
      malformed_samples: [],
      rotations: 0,
      truncated?: false
    }
  end

  @doc """
  Returns a brief summary string for logging or debugging.
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{source: source, exists?: exists?, size: size, offset: offset}) do
    "#{source} exists=#{exists?} size=#{size || "?"} offset=#{offset || "?"}"
  end
end
