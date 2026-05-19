defmodule Embassy.Test.FailingReadAdapter do
  @moduledoc false

  # Wraps Plug.Adapters.Test.Conn so all callbacks pass through except
  # read_req_body/2, which always returns an error tuple.

  @behaviour Plug.Conn.Adapter

  @impl Plug.Conn.Adapter
  def chunk(state, chunk), do: Plug.Adapters.Test.Conn.chunk(state, chunk)

  @impl Plug.Conn.Adapter
  def get_http_protocol(state), do: Plug.Adapters.Test.Conn.get_http_protocol(state)

  @impl Plug.Conn.Adapter
  def get_peer_data(state), do: Plug.Adapters.Test.Conn.get_peer_data(state)

  @impl Plug.Conn.Adapter
  def get_sock_data(state), do: Plug.Adapters.Test.Conn.get_sock_data(state)

  @impl Plug.Conn.Adapter
  def get_ssl_data(state), do: Plug.Adapters.Test.Conn.get_ssl_data(state)

  @impl Plug.Conn.Adapter
  def inform(state, status, headers), do: Plug.Adapters.Test.Conn.inform(state, status, headers)

  @impl Plug.Conn.Adapter
  def push(state, path, headers), do: Plug.Adapters.Test.Conn.push(state, path, headers)

  @impl Plug.Conn.Adapter
  def send_chunked(state, status, headers),
    do: Plug.Adapters.Test.Conn.send_chunked(state, status, headers)

  @impl Plug.Conn.Adapter
  def send_file(state, status, headers, file, offset, length),
    do: Plug.Adapters.Test.Conn.send_file(state, status, headers, file, offset, length)

  @impl Plug.Conn.Adapter
  def send_resp(state, status, headers, body),
    do: Plug.Adapters.Test.Conn.send_resp(state, status, headers, body)

  @impl Plug.Conn.Adapter
  def upgrade(state, protocol, opts), do: Plug.Adapters.Test.Conn.upgrade(state, protocol, opts)

  @impl Plug.Conn.Adapter
  def read_req_body(_state, _opts), do: {:error, :test_failure}
end
