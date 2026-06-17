defmodule Embassy.DualRoute.ComparatorTest do
  use ExUnit.Case, async: true

  alias Embassy.DualRoute.{Captured, Comparator}

  defp cap(status, body, headers \\ [{"content-type", "application/json"}]) do
    %Captured{status: status, headers: headers, body: body}
  end

  test ":status_only matches on equal status regardless of body" do
    assert Comparator.compare(:status_only, cap(200, "a"), cap(200, "b")) == :match

    assert {:diff, %{reason: :status}} =
             Comparator.compare(:status_only, cap(200, "a"), cap(500, "a"))
  end

  test ":json deep-compares decoded bodies" do
    a = cap(200, ~s({"a":1,"b":2}))
    b = cap(200, ~s({"b":2,"a":1}))
    assert Comparator.compare(:json, a, b) == :match

    c = cap(200, ~s({"a":1,"b":3}))
    assert {:diff, _} = Comparator.compare(:json, a, c)
  end

  test ":json with ignore drops volatile fields before comparing" do
    a = cap(200, ~s({"id":1,"name":"x"}))
    b = cap(200, ~s({"id":2,"name":"x"}))
    assert Comparator.compare({:json, ignore: ["id"]}, a, b) == :match
  end

  test ":json flags a non-JSON body" do
    assert {:diff, %{reason: :decode_error}} =
             Comparator.compare(:json, cap(200, "not json"), cap(200, "also not"))
  end

  test ":exact requires identical body and filtered headers" do
    a = cap(200, "x", [{"content-type", "text/plain"}, {"date", "monday"}])
    b = cap(200, "x", [{"content-type", "text/plain"}, {"date", "tuesday"}])
    assert Comparator.compare(:exact, a, b) == :match

    c = cap(200, "y", [{"content-type", "text/plain"}])
    assert {:diff, _} = Comparator.compare(:exact, a, c)
  end

  test "a custom fn is called as-is" do
    cmp = fn _control, _candidate -> {:diff, %{reason: :custom}} end
    assert {:diff, %{reason: :custom}} = Comparator.compare(cmp, cap(200, "a"), cap(200, "a"))
  end

  test ":html matches when bodies differ only in whitespace" do
    a = cap(200, "<div>  hello\n  world </div>")
    b = cap(200, "<div> hello world </div>")
    assert Comparator.compare(:html, a, b) == :match

    c = cap(200, "<div>goodbye</div>")
    assert {:diff, %{reason: :html_body}} = Comparator.compare(:html, a, c)
  end
end
