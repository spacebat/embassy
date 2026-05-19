defmodule Embassy.Config do
  @moduledoc """
  Per-instance configuration accessor.

  Reads a snapshot stashed in the per-instance Registry metadata by the
  `Embassy` supervisor. Lookup is O(1) and safe to call once per
  request.
  """

  @typedoc """
  Internal snapshot shape. Fields may be added without breaking
  consumers; treat the map as opaque and use the public accessors.
  """
  @opaque snapshot :: %{name: atom(), finch: atom()}

  @doc """
  Return the config snapshot for the named Embassy instance.

  Raises `Embassy.NotStartedError` if no Embassy supervisor with the
  given name is running.
  """
  @spec snapshot(atom()) :: snapshot()
  def snapshot(name) when is_atom(name) do
    case Registry.meta(Embassy.registry_name(name), :config) do
      {:ok, snapshot} -> snapshot
      :error -> raise Embassy.NotStartedError, name: name
    end
  rescue
    ArgumentError -> reraise Embassy.NotStartedError, [name: name], __STACKTRACE__
  end
end
