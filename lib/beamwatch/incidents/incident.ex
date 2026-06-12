defmodule BeamWatch.Incidents.Incident do
  @moduledoc """
  Represents a single active or historical incident.

  An incident is identified by the combination of its type and the affected
  resource (e.g. `{:container_restart_loop, "plex"}`). It tracks when it was
  first and last seen, the evidence that supports it, and its current status.
  """

  @type status :: :active | :acknowledged | :silenced | :resolved
  @type severity :: :high | :medium
  @type id :: {atom(), String.t()}

  defstruct [
    :id,
    :type,
    :resource,
    :severity,
    :status,
    :first_seen,
    :last_seen,
    :evidence,
    :silenced?
  ]

  @type t :: %__MODULE__{
          id: id(),
          type: atom(),
          resource: String.t(),
          severity: severity(),
          status: status(),
          first_seen: DateTime.t(),
          last_seen: DateTime.t(),
          evidence: [BeamWatch.Ingest.Event.t()],
          silenced?: boolean()
        }

  @doc """
  Creates a new incident with the given type and resource key.
  """
  @spec new(atom(), String.t(), keyword()) :: t()
  def new(type, resource, opts \\ []) do
    %__MODULE__{
      id: {type, resource},
      type: type,
      resource: resource,
      severity: Keyword.get(opts, :severity, :medium),
      status: :active,
      first_seen: Keyword.get(opts, :first_seen, DateTime.utc_now()),
      last_seen: Keyword.get(opts, :last_seen, DateTime.utc_now()),
      evidence: Keyword.get(opts, :evidence, []),
      silenced?: Keyword.get(opts, :silenced?, false)
    }
  end
end
