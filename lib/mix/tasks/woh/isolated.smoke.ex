defmodule Woh.Tool.IsolatedSmoke do
  @moduledoc false

  @max_archive_bytes 50_000_000
  @max_extracted_bytes 100_000_000

  def run(project) do
    with :ok <- clean_tree(project) do
      temporary =
        Path.join(
          System.tmp_dir!(),
          "wotex-home-clean-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
        )

      File.mkdir!(temporary)
      File.chmod!(temporary, 0o700)

      try do
        checkout = Path.join(temporary, "home")
        File.mkdir!(checkout)
        archive = Path.join(temporary, "source.tar")

        with :ok <- make_archive(project, archive),
             :ok <- extract_archive(archive, checkout),
             :ok <- stage_pinned_git_deps(project, checkout),
             :ok <- build_and_smoke(checkout) do
          {:ok, "isolated committed checkout passed offline-cache release smoke"}
        end
      after
        File.rm_rf!(temporary)
      end
    end
  end

  defp clean_tree(project) do
    case System.cmd("git", ["status", "--porcelain", "--untracked-files=normal"],
           cd: project,
           stderr_to_stdout: true
         ) do
      {"", 0} -> :ok
      {_, 0} -> {:error, "commit the source tree before the isolated smoke check"}
      {output, status} -> {:error, "git status exited #{status}: #{String.trim(output)}"}
    end
  end

  defp make_archive(project, archive) do
    case System.cmd("git", ["archive", "--format=tar", "--output=#{archive}", "HEAD"],
           cd: project,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        case File.lstat(archive) do
          {:ok, %File.Stat{type: :regular, size: size}}
          when size > 0 and size <= @max_archive_bytes ->
            :ok

          _ ->
            {:error, "committed archive is missing or exceeds the development bound"}
        end

      {output, status} ->
        {:error, "git archive exited #{status}: #{String.trim(output)}"}
    end
  end

  defp extract_archive(archive, checkout) do
    case :erl_tar.extract(String.to_charlist(archive),
           cwd: String.to_charlist(checkout),
           max_size: @max_extracted_bytes
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot extract committed source: #{inspect(reason)}"}
    end
  end

  @doc false
  def stage_pinned_git_deps(project, checkout, pins \\ WotexHome.MixProject.source_pins()) do
    pins
    |> Enum.reduce_while(:ok, fn {app, pin}, :ok ->
      source = Path.join([project, "deps", Atom.to_string(app)])
      destination = Path.join([checkout, "deps", Atom.to_string(app)])

      case System.cmd("git", ["-C", source, "rev-parse", "HEAD"], stderr_to_stdout: true) do
        {revision, 0} when is_binary(revision) ->
          if String.trim(revision) == pin do
            File.mkdir_p!(Path.dirname(destination))

            case File.cp_r(source, destination) do
              {:ok, _} ->
                case reset_staged_dependency(destination, pin) do
                  :ok -> {:cont, :ok}
                  {:error, reason} -> {:halt, {:error, "cannot stage #{app}: #{reason}"}}
                end

              {:error, reason, _} ->
                {:halt, {:error, "cannot stage #{app}: #{reason}"}}
            end
          else
            {:halt, {:error, "#{app} is not checked out at its pinned Git revision"}}
          end

        _ ->
          {:halt, {:error, "fetch pinned Git dependency #{app} before isolated smoke"}}
      end
    end)
  end

  defp reset_staged_dependency(destination, pin) do
    for args <- [["reset", "--hard", pin], ["clean", "-fdx"]] do
      case System.cmd("git", ["-C", destination | args], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, _} -> throw({:stage_failed, String.trim(output)})
      end
    end

    :ok
  catch
    {:stage_failed, reason} -> {:error, reason}
  end

  defp build_and_smoke(checkout) do
    environment = [
      {"HEX_OFFLINE", "1"},
      {"MIX_ENV", "prod"},
      {"WOTEX_HOME_GIT_DEPS", "1"},
      {"GIT_TERMINAL_PROMPT", "0"}
    ]

    for args <- [
          ["deps.get", "--check-locked"],
          ["release", "--overwrite"],
          ["woh.release.smoke", "_build/prod/rel/wotex_home/bin/wotex_home"]
        ] do
      Mix.shell().info("isolated mix #{Enum.join(args, " ")}")

      case System.cmd("mix", args,
             cd: checkout,
             env: environment,
             into: IO.stream(:stdio, :line),
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {_, status} -> throw({:build_failed, args, status})
      end
    end

    :ok
  catch
    {:build_failed, args, status} ->
      {:error, "isolated mix #{Enum.join(args, " ")} exited #{status}"}
  end
end

defmodule Mix.Tasks.Woh.Isolated.Smoke do
  @moduledoc """
  Builds and smoke-tests the committed Home source in an isolated checkout.

  Run `WOTEX_HOME_GIT_DEPS=1 mix deps.get` once, then run
  `mix woh.isolated.smoke` from a clean tree after caching the locked Hex
  packages. The task archives `HEAD`, stages only the exact checked-out Git
  dependencies in the temporary checkout, builds with `HEX_OFFLINE=1`, and
  runs the release smoke check. Sibling development checkouts are not used.
  Another CPU or OS needs a separate qualification run.
  """

  @shortdoc "Build and smoke-test the committed source offline"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.IsolatedSmoke.run(File.cwd!()) do
      {:ok, message} -> Mix.shell().info(message)
      {:error, reason} -> Mix.raise("isolated checkout smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.isolated.smoke")
end
