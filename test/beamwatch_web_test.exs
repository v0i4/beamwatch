defmodule BeamWatchWebTest do
  use ExUnit.Case, async: true

  test "static_paths/0 returns expected static asset paths" do
    assert BeamWatchWeb.static_paths() == ~w(assets fonts images favicon.ico robots.txt)
  end
end
