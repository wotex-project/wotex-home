defmodule Woh.Tool.Hash do
  @moduledoc false

  def sha256(path) do
    path
    |> File.stream!([], 1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
