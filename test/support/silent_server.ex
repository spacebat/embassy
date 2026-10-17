defmodule Embassy.Test.SilentServer do
  @moduledoc false

  # A TCP listener that accepts connections and never replies, for
  # exercising client timeouts. Bypass turns a client hanging up
  # mid-handler into an exit in the test process, so it can't do this.
  # Each accepted connection sends `{:silent_accept, port}` to `notify`.

  @doc "Start the listener, linked to the caller. Returns the port."
  def start(notify \\ nil) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    pid =
      spawn_link(fn ->
        receive do
          :go -> accept_loop(listener, notify, port, [])
        end
      end)

    :ok = :gen_tcp.controlling_process(listener, pid)
    send(pid, :go)
    port
  end

  defp accept_loop(listener, notify, port, held) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        if notify, do: send(notify, {:silent_accept, port})
        accept_loop(listener, notify, port, [socket | held])

      {:error, _} ->
        :ok
    end
  end
end
