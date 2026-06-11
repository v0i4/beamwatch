defmodule BeamWatch.ApplicationTest do
  use ExUnit.Case, async: true

  test "config_change/3 delegates to the endpoint" do
    assert :ok = BeamWatch.Application.config_change([], [], [])
  end
end
