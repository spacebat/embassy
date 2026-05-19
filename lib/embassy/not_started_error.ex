defmodule Embassy.NotStartedError do
  @moduledoc """
  Raised when `Embassy.Config.snapshot/1` is called for an instance
  name that does not correspond to a running `Embassy` supervisor.

  The most common cause is a typo in the `:embassy` opt of a plug call
  site, or forgetting to add `{Embassy, name: ..., finch: ...}` to the
  consumer application's supervision tree.
  """

  defexception [:name]

  @impl true
  def message(%__MODULE__{name: name}) do
    "Embassy instance #{inspect(name)} is not started. " <>
      "Make sure {Embassy, name: #{inspect(name)}, finch: ...} is in your " <>
      "application's supervision tree."
  end
end
