defmodule BeamWatch.Incidents.Detector do
  @moduledoc """
  Behaviour for incident detectors.

  Each detector module implements `detect/2`, receiving the current engine
  state and a new event, returning updated engine state.
  """

  @callback detect(map(), BeamWatch.Ingest.Event.t()) :: map()
end
