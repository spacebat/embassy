defmodule EmbassyTest do
  use ExUnit.Case
  doctest Embassy

  test "greets the world" do
    assert Embassy.hello() == :world
  end
end
