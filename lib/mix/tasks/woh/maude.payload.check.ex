defmodule Woh.Tool.MaudePayload do
  @moduledoc false

  @asset_sha256 "95851274f57b3853aab833674e2b770ed800f38fb1f3d03c97dcac56346c13dc"
  @file_sha256 %{
    "maude" => "266eed04679fde6029a18e5e2b1828223d4a7169ac55503aa15d67e126792fbf",
    "file.maude" => "6c579bc7799e08adafeb1813abd6f7f8e46cf2c6b6e7542559f38cbd331d28d0",
    "linear.maude" => "5b01df9ee29d875a1cb3fd47c0fd4fce0e8de98aa694b39fad406aa7fc51f9c9",
    "machine-int.maude" => "79184b2f0096d5c46ec7042bcb9d4393c4714090cf0da5fae9e7087c0ab6a6a0",
    "metaInterpreter.maude" => "9da39cd94099139514bdbf22f633fbb36371568a2d99b944c8f050710c9074c6",
    "model-checker.maude" => "be53123786b18da5a91ac0fa0436e1d72ec87fc76076c1a12398d4d8166948d0",
    "prelude.maude" => "8f03c0be1999dfedff5fbabc1473b20359681d6cfa1dece6f47626e1a827de75",
    "prng.maude" => "32735b8096c0fa034eeedabdca44ff4c460189295dd330ad50243e38518b493b",
    "process.maude" => "ab3497ba8a569f7605b47f226d15f348a71ef7bea156aa9f46dc8f61a9c3f1e9",
    "smt.maude" => "c711af83c8eeb29498b7885fb50cfafe95f33900659bf8405bd8d4bca63d561f",
    "socket.maude" => "6f0eaaa70ff87cb49e4e1778189e4dd5a146ca75310a8691cdc10a6944f7b0c5",
    "term-order.maude" => "f29c722972c95b3e698400403fb97b12b9657f202c8845d7b71baede47d88556",
    "time.maude" => "19612ea37c4bff289baf70bceae38c4305c2519cb36e07c55b82a80d76be18d1",
    "maude.sty" => "d8c75d6cacb478a28901c25b8a820fd8a7b28ad0672c1c77d5122e2917b83cc5"
  }
  @max_file_bytes 8_000_000
  @max_asset_bytes 8_000_000

  def files, do: @file_sha256

  def check_directory(directory, release? \\ false) do
    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory}} ->
        allowed =
          @file_sha256
          |> Map.keys()
          |> Enum.map(&local_name/1)
          |> MapSet.new()

        allowed =
          if release?,
            do: allowed,
            else: MapSet.union(allowed, MapSet.new(~w(maude-darwin-x64 maude-linux-x64)))

        with {:ok, names} <- File.ls(directory),
             true <- MapSet.new(names) == allowed do
          Enum.reduce_while(@file_sha256, {:ok, map_size(@file_sha256)}, fn {name, expected}, _ ->
            path = Path.join(directory, local_name(name))

            case bounded_digest(path, @max_file_bytes) do
              {:ok, ^expected} -> {:cont, {:ok, map_size(@file_sha256)}}
              {:ok, _} -> {:halt, {:error, "Maude payload hash differs: #{name}"}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        else
          _ -> {:error, "Maude payload file set differs from pinned asset"}
        end

      _ ->
        {:error, "Maude payload directory missing or linked"}
    end
  end

  def check_archive(path) do
    with {:ok, @asset_sha256} <- bounded_digest(path, @max_asset_bytes),
         {:ok, entries} <- :zip.list_dir(String.to_charlist(path)),
         {:ok, names} <- archive_names(entries),
         true <- length(names) == map_size(@file_sha256),
         true <- MapSet.new(names) == MapSet.new(Map.keys(@file_sha256)),
         {:ok, contents} <- :zip.unzip(String.to_charlist(path), [:memory]),
         true <- length(contents) == map_size(@file_sha256),
         true <-
           Enum.all?(contents, fn {name, bytes} ->
             key = to_string(name)

             byte_size(bytes) <= @max_file_bytes and
               Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @file_sha256[key]
           end) do
      {:ok, length(names)}
    else
      {:ok, _} -> {:error, "Maude release archive hash differs"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "Maude release archive members differ"}
    end
  end

  defp archive_names(entries) do
    entries
    |> Enum.reject(&match?({:zip_comment, _}, &1))
    |> Enum.reduce_while({:ok, []}, fn
      {:zip_file, name, info, _, _, _}, {:ok, names} ->
        size = elem(info, 1)

        if is_integer(size) and size >= 0 and size <= @max_file_bytes do
          {:cont, {:ok, [to_string(name) | names]}}
        else
          {:halt, {:error, "oversized Maude release archive member"}}
        end

      _, _ ->
        {:halt, {:error, "Maude release archive members differ"}}
    end)
  end

  defp bounded_digest(path, limit) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= limit ->
        {:ok, Woh.Tool.Hash.sha256(path)}

      _ ->
        {:error, "missing, linked or oversized Maude file: #{Path.basename(path)}"}
    end
  end

  defp local_name("maude"), do: "maude-darwin-arm64"
  defp local_name(name), do: name
end

defmodule Mix.Tasks.Woh.Maude.Payload.Check do
  @moduledoc """
  Checks the pinned Maude 3.5.1 macOS arm64 payload bytes.

  Run `mix woh.maude.payload.check DIRECTORY` for the pinned dependency's private tree,
  or add `--release` for an assembled release. `--archive ZIP` additionally
  checks the tagged upstream asset. The result establishes byte provenance;
  license obligations and native dependency closure have separate gates.
  """

  @shortdoc "Check pinned Maude payload bytes"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {options, positionals, invalid} =
      OptionParser.parse(args, strict: [release: :boolean, archive: :string])

    case {positionals, invalid} do
      {[directory], []} ->
        with {:ok, count} <-
               Woh.Tool.MaudePayload.check_directory(directory, options[:release] || false),
             {:ok, _} <- maybe_archive(options[:archive]) do
          Mix.shell().info("verified #{count} Maude 3.5.1 macOS arm64 payload files")
        else
          {:error, reason} -> Mix.raise("Maude payload check failed: #{reason}")
        end

      _ ->
        Mix.raise("usage: mix woh.maude.payload.check DIRECTORY [--release] [--archive ZIP]")
    end
  end

  defp maybe_archive(nil), do: {:ok, :not_requested}
  defp maybe_archive(path), do: Woh.Tool.MaudePayload.check_archive(path)
end
