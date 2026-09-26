defmodule ExMaude.Config do
  @moduledoc """
  Runtime configuration readers shared by ExMaude components.

  Values are read when an operation starts, so changing application
  configuration affects new commands without recompiling the project.
  """

  @maximum_response_bytes 2_147_483_000

  @doc """
  Returns the configured default timeout when it is a positive integer.

  Invalid or missing configuration falls back to the positive value supplied
  by the caller.
  """
  @spec timeout(pos_integer()) :: pos_integer()
  def timeout(fallback) when is_integer(fallback) and fallback > 0 do
    case Application.get_env(:ex_maude, :timeout, fallback) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> fallback
    end
  end

  @doc """
  Returns the configured response-size ceiling when it is a positive integer.

  The upper bound keeps the value representable by every supported native
  backend. Invalid, missing, or larger values fall back to the caller's
  positive value.
  """
  @spec max_response_bytes(pos_integer()) :: pos_integer()
  def max_response_bytes(fallback) when is_integer(fallback) and fallback > 0 do
    case Application.get_env(:ex_maude, :max_response_bytes, fallback) do
      bytes when is_integer(bytes) and bytes in 1..@maximum_response_bytes -> bytes
      _ -> fallback
    end
  end
end
