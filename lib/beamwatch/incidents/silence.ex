defmodule BeamWatch.Incidents.Silence do
  @moduledoc """
  Represents a silence applied to an incident or incident type.

  `scope` is either `:incident` (targets a specific incident by its id) or
  `:type` (silences all incidents of that type). `key` is the incident id
  (`{type, resource}`) or the type atom respectively.
  """

  defstruct [:scope, :key]

  @type scope :: :incident | :type

  @type t :: %__MODULE__{
          scope: scope(),
          key: term()
        }

  @doc """
  Creates a new silence.
  """
  @spec new(scope(), term()) :: t()
  def new(scope, key) do
    %__MODULE__{scope: scope, key: key}
  end
end
