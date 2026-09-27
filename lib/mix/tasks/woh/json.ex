defmodule Woh.Tool.Json do
  @moduledoc false

  def read(path, limit) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size > 0 and size <= limit,
         {:ok, bytes} <- File.read(path) do
      try do
        case JSON.decode(bytes, nil,
               object_push: fn key, value, pairs ->
                 if Enum.any?(pairs, fn {existing, _} -> existing == key end),
                   do: raise(ArgumentError, "duplicate JSON member: #{key}")

                 [{key, value} | pairs]
               end
             ) do
          {value, nil, ""} -> {:ok, value}
          _ -> {:error, "invalid JSON: #{Path.basename(path)}"}
        end
      rescue
        error in ArgumentError -> {:error, Exception.message(error)}
      end
    else
      _ -> {:error, "JSON file is unavailable or overlong: #{Path.basename(path)}"}
    end
  end
end
