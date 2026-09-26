defmodule ExMaude.ConfigTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ExMaude.Config

  setup do
    original_timeout = Application.get_env(:ex_maude, :timeout)
    original_limit = Application.get_env(:ex_maude, :max_response_bytes)

    on_exit(fn ->
      restore_env(:timeout, original_timeout)
      restore_env(:max_response_bytes, original_limit)
    end)

    :ok
  end

  test "timeout accepts a positive configured value and rejects invalid values" do
    Application.put_env(:ex_maude, :timeout, 123)
    assert Config.timeout(500) == 123

    Application.put_env(:ex_maude, :timeout, 0)
    assert Config.timeout(500) == 500
  end

  test "max_response_bytes accepts representable positive values" do
    Application.put_env(:ex_maude, :max_response_bytes, 4096)
    assert Config.max_response_bytes(1024) == 4096
  end

  test "max_response_bytes rejects invalid and native-unrepresentable values" do
    Application.put_env(:ex_maude, :max_response_bytes, 0)
    assert Config.max_response_bytes(1024) == 1024

    Application.put_env(:ex_maude, :max_response_bytes, 2_147_483_001)
    assert Config.max_response_bytes(1024) == 1024
  end

  defp restore_env(key, nil), do: Application.delete_env(:ex_maude, key)
  defp restore_env(key, value), do: Application.put_env(:ex_maude, key, value)
end
