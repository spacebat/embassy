defmodule Embassy.BodyCache do
  @moduledoc """
  A `Plug.Parsers` `:body_reader` that stashes the raw request body on
  `conn.assigns[:raw_body]` so downstream plugs (notably
  `Embassy.ReverseProxy`) can re-emit it after the parser has consumed
  it.

  Without this, the proxy reads an empty body but forwards the original
  `Content-Length` header, and the upstream backend waits forever for
  bytes that never come.

  ## Wiring

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason,
        body_reader: {Embassy.BodyCache, :read_body, []}

  Then in `Embassy.ReverseProxy.call/2`, the raw body is recovered via
  `Embassy.BodyCache.fetch(conn)`.
  """

  alias Plug.Conn

  @doc """
  `Plug.Parsers`-compatible body reader. Delegates to
  `Plug.Conn.read_body/2` and appends each chunk to `conn.assigns[:raw_body]`
  as iodata.
  """
  @spec read_body(Conn.t(), keyword()) ::
          {:ok, binary(), Conn.t()}
          | {:more, binary(), Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    case Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, append(conn, body)}
      {:more, body, conn} -> {:more, body, append(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Concatenate the cached body chunks into a single binary in their
  original arrival order. Returns `""` when no body has been recorded.
  """
  @spec fetch(Conn.t()) :: binary()
  def fetch(conn) do
    conn.assigns
    |> Map.get(:raw_body, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp append(conn, chunk) do
    Conn.assign(conn, :raw_body, [chunk | Map.get(conn.assigns, :raw_body, [])])
  end
end
