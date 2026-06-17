defmodule Embassy.DualRoute.Captured do
  @moduledoc """
  A normalized snapshot of one side's HTTP response: status, response
  headers (hop-by-hop filtered, lower-cased), and the full body. Both
  proxy and plug targets produce this shape for the comparator.
  """

  @enforce_keys [:status, :headers, :body]
  defstruct [:status, :headers, :body]

  @type t :: %__MODULE__{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }
end
