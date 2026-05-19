defmodule Embassy.ConfigTest do
  use ExUnit.Case, async: true

  test "Embassy.NotStartedError carries the instance name in its message" do
    err = %Embassy.NotStartedError{name: MyApp.Embassy}
    assert Exception.message(err) =~ "MyApp.Embassy"
    assert Exception.message(err) =~ "not started"
  end
end
