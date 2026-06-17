defmodule EmbassyTest do
  use ExUnit.Case, async: true

  setup do
    start_supervised!({Finch, name: EmbassyTest.Finch})
    :ok
  end

  test "starts cleanly with name and finch" do
    {:ok, pid} =
      start_supervised({Embassy, name: EmbassyTest.Instance, finch: EmbassyTest.Finch})

    assert Process.alive?(pid)
  end

  test "raises ArgumentError when :name is missing" do
    assert_raise ArgumentError, ~r/required option :name/, fn ->
      Embassy.start_link(finch: EmbassyTest.Finch)
    end
  end

  test "raises ArgumentError when :finch is missing" do
    assert_raise ArgumentError, ~r/required option :finch/, fn ->
      Embassy.start_link(name: EmbassyTest.MissingFinch)
    end
  end

  test "multiple named instances coexist" do
    {:ok, _a} =
      start_supervised(
        {Embassy, name: EmbassyTest.A, finch: EmbassyTest.Finch},
        id: :embassy_a
      )

    {:ok, _b} =
      start_supervised(
        {Embassy, name: EmbassyTest.B, finch: EmbassyTest.Finch},
        id: :embassy_b
      )

    assert Process.whereis(EmbassyTest.A)
    assert Process.whereis(EmbassyTest.B)
  end

  test "starts a per-instance Task.Supervisor and exposes it on the snapshot" do
    name = :"embassy_test_#{System.unique_integer([:positive])}"
    start_supervised!({Embassy, name: name, finch: :test_finch})

    task_sup = Module.concat(name, TaskSupervisor)
    assert is_pid(Process.whereis(task_sup))

    snapshot = Embassy.Config.snapshot(name)
    assert snapshot.finch == :test_finch
    assert snapshot.task_supervisor == task_sup
  end
end
