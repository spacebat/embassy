defmodule Embassy.DualRoute.CaptureAdapter do
  @moduledoc """
  A `Plug.Conn.Adapter` that buffers a plug's response in memory instead
  of writing it to a socket, so `Embassy.DualRoute` can run a candidate
  (or control) plug and capture what it *would* have sent.

  Use `build_conn/2` to clone a live conn onto this adapter, run the
  target plug, then `captured/1` to read the response back as an
  `Embassy.DualRoute.Captured`.
  """

  @behaviour Plug.Conn.Adapter

  alias Embassy.DualRoute.Captured
  alias Embassy.Proxy

  @doc """
  Clone `template` onto this adapter: preserve request fields and
  assigns, seed the adapter with `req_body`, and reset response state so
  the target plug starts from a clean slate.
  """
  @spec build_conn(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def build_conn(template, req_body) do
    payload = %{
      req_body: req_body,
      status: nil,
      headers: [],
      body: "",
      peer_data: peer_data(template),
      http_protocol: http_protocol(template)
    }

    %{
      template
      | adapter: {__MODULE__, payload},
        state: :unset,
        status: nil,
        resp_headers: [],
        resp_body: nil,
        halted: false
    }
  end

  @doc "Read the buffered response out of a conn that used this adapter."
  @spec captured(Plug.Conn.t()) :: Captured.t()
  def captured(%Plug.Conn{adapter: {__MODULE__, payload}}) do
    %Captured{
      status: payload.status,
      headers: Proxy.response_headers(payload.headers),
      body: IO.iodata_to_binary(payload.body)
    }
  end

  defp peer_data(conn) do
    Plug.Conn.get_peer_data(conn)
  rescue
    _ -> %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}
  end

  defp http_protocol(conn) do
    Plug.Conn.get_http_protocol(conn)
  rescue
    _ -> :"HTTP/1.1"
  end

  # --- Plug.Conn.Adapter callbacks --------------------------------------

  @impl Plug.Conn.Adapter
  def send_resp(payload, status, headers, body) do
    body = IO.iodata_to_binary(body)
    {:ok, body, %{payload | status: status, headers: headers, body: body}}
  end

  @impl Plug.Conn.Adapter
  def send_file(payload, status, headers, path, offset, length) do
    %File.Stat{type: :regular, size: size} = File.stat!(path)
    length = if length == :all, do: size, else: length

    {:ok, data} =
      File.open!(path, [:read, :binary], fn device -> :file.pread(device, offset, length) end)

    {:ok, data, %{payload | status: status, headers: headers, body: data}}
  end

  @impl Plug.Conn.Adapter
  def send_chunked(payload, status, headers) do
    {:ok, "", %{payload | status: status, headers: headers, body: ""}}
  end

  @impl Plug.Conn.Adapter
  def chunk(payload, chunk) do
    body = payload.body <> IO.iodata_to_binary(chunk)
    {:ok, body, %{payload | body: body}}
  end

  @impl Plug.Conn.Adapter
  def read_req_body(payload, opts) do
    max = Keyword.get(opts, :length, 8_000_000)
    body = payload.req_body
    size = min(byte_size(body), max)
    data = :binary.part(body, 0, size)
    rest = :binary.part(body, size, byte_size(body) - size)
    tag = if rest == "", do: :ok, else: :more
    {tag, data, %{payload | req_body: rest}}
  end

  @impl Plug.Conn.Adapter
  def inform(_payload, _status, _headers), do: :ok

  @impl Plug.Conn.Adapter
  def upgrade(payload, _protocol, _opts), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def push(_payload, _path, _headers), do: {:error, :not_supported}

  @impl Plug.Conn.Adapter
  def get_peer_data(payload), do: payload.peer_data

  @impl Plug.Conn.Adapter
  def get_http_protocol(payload), do: payload.http_protocol

  @impl Plug.Conn.Adapter
  def get_sock_data(_payload), do: %{address: {127, 0, 0, 1}, port: 0}

  @impl Plug.Conn.Adapter
  def get_ssl_data(_payload), do: nil
end
