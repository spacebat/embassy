defmodule Embassy.DualRoute.Comparator do
  @moduledoc """
  Compares a control and candidate `Embassy.DualRoute.Captured`.

  Built-in strategies: `:status_only`, `:json` (with optional
  `{:json, ignore: [field, ...]}`), `:html`, and `:exact` (with optional
  `{:exact, ignore_headers: [name, ...]}`). A 2-arity function is called
  directly. Every strategy returns `:match | {:diff, detail_map}`.
  """

  alias Embassy.DualRoute.Captured

  @default_volatile_headers ~w(date set-cookie x-request-id etag age x-runtime server-timing)

  @type spec ::
          :status_only
          | :json
          | {:json, keyword()}
          | :html
          | :exact
          | {:exact, keyword()}
          | (Captured.t(), Captured.t() -> :match | {:diff, map()})

  @spec compare(spec(), Captured.t(), Captured.t()) :: :match | {:diff, map()}
  def compare(fun, control, candidate) when is_function(fun, 2), do: fun.(control, candidate)

  def compare(:status_only, control, candidate), do: status_match(control, candidate, :match)

  def compare(:json, c, k), do: compare({:json, []}, c, k)

  def compare({:json, opts}, control, candidate) do
    ignore = Keyword.get(opts, :ignore, [])

    status_match(control, candidate, fn ->
      if json_content_type?(control) and json_content_type?(candidate) do
        compare_json_bodies(control.body, candidate.body, ignore)
      else
        {:diff, %{reason: :not_json}}
      end
    end)
  end

  def compare(:html, control, candidate) do
    status_match(control, candidate, fn ->
      a = normalize_html(control.body)
      b = normalize_html(candidate.body)
      if a == b, do: :match, else: {:diff, %{reason: :html_body}}
    end)
  end

  def compare(:exact, c, k), do: compare({:exact, []}, c, k)

  def compare({:exact, opts}, control, candidate) do
    ignore = Keyword.get(opts, :ignore_headers, []) ++ @default_volatile_headers

    status_match(control, candidate, fn ->
      headers_a = filter_headers(control.headers, ignore)
      headers_b = filter_headers(candidate.headers, ignore)

      cond do
        control.body != candidate.body -> {:diff, %{reason: :body}}
        headers_a != headers_b -> {:diff, %{reason: :headers}}
        true -> :match
      end
    end)
  end

  defp compare_json_bodies(control_body, candidate_body, ignore) do
    with {:ok, a} <- decode_json(control_body),
         {:ok, b} <- decode_json(candidate_body) do
      a = drop_fields(a, ignore)
      b = drop_fields(b, ignore)
      if a == b, do: :match, else: {:diff, %{reason: :json_body, control: a, candidate: b}}
    else
      :error -> {:diff, %{reason: :decode_error}}
    end
  end

  # Run `on_match` only when statuses match; otherwise report a status diff.
  # `on_match` is either the literal `:match` atom or a 0-arity function.
  defp status_match(%{status: s}, %{status: s}, :match), do: :match

  defp status_match(%{status: s}, %{status: s}, on_match) when is_function(on_match, 0),
    do: on_match.()

  defp status_match(control, candidate, _on_match),
    do: {:diff, %{reason: :status, control: control.status, candidate: candidate.status}}

  defp json_content_type?(%{headers: headers}) do
    case List.keyfind(headers, "content-type", 0) do
      {"content-type", value} -> value |> String.downcase() |> String.contains?("json")
      _ -> false
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> :error
    end
  end

  defp drop_fields(map, fields) when is_map(map) do
    map
    |> Map.drop(fields)
    |> Map.new(fn {k, v} -> {k, drop_fields(v, fields)} end)
  end

  defp drop_fields(list, fields) when is_list(list), do: Enum.map(list, &drop_fields(&1, fields))
  defp drop_fields(other, _fields), do: other

  defp normalize_html(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp filter_headers(headers, ignore) do
    headers
    |> Enum.reject(fn {name, _} -> name in ignore end)
    |> Enum.sort()
  end
end
