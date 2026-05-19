defmodule Embassy.ConfigTest do
  use ExUnit.Case, async: true

  test "Embassy.NotStartedError carries the instance name in its message" do
    err = %Embassy.NotStartedError{name: MyApp.Embassy}
    assert Exception.message(err) =~ "MyApp.Embassy"
    assert Exception.message(err) =~ "not started"
  end

  describe "snapshot/1" do
    setup do
      start_supervised!({Finch, name: Embassy.ConfigTest.Finch})

      start_supervised!(
        {Embassy, name: Embassy.ConfigTest.Instance, finch: Embassy.ConfigTest.Finch}
      )

      :ok
    end

    test "returns the snapshot for a running instance" do
      assert %{name: Embassy.ConfigTest.Instance, finch: Embassy.ConfigTest.Finch} =
               Embassy.Config.snapshot(Embassy.ConfigTest.Instance)
    end

    test "raises NotStartedError for an unknown instance name" do
      assert_raise Embassy.NotStartedError, ~r/Definitely.Not.Started/, fn ->
        Embassy.Config.snapshot(Definitely.Not.Started)
      end
    end
  end
end
