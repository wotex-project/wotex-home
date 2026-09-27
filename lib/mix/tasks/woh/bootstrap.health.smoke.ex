defmodule Woh.Tool.BootstrapHealthSmoke do
  @moduledoc false

  import Bitwise

  def run(project) do
    directory =
      Path.join(
        "/tmp",
        "wh-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    data = Path.join(directory, "private")
    environment = [{"WOTEX_HOME_DATA_DIR", data}]

    try do
      {first, first_status} =
        System.cmd("mix", ["run", "bin/bootstrap_health.exs"],
          cd: project,
          env: environment,
          stderr_to_stdout: true
        )

      credentials =
        first
        |> String.split("\n")
        |> Enum.filter(&Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, &1))

      with true <- first_status == 0 and length(credentials) == 1,
           true <- private_mode?(data, :directory, 0o700),
           true <- private_mode?(Path.join(data, "home.sqlite"), :regular, 0o600),
           true <- not File.exists?(Path.join(data, "ipc/home.sock")) do
        credential = hd(credentials)

        {repeated, repeated_status} =
          System.cmd("mix", ["run", "bin/bootstrap_health.exs"],
            cd: project,
            env: environment,
            stderr_to_stdout: true
          )

        if repeated_status != 0 and String.contains?(repeated, "principal_exists") and
             not String.contains?(repeated, credential) do
          {:ok, "one-time read-only health bootstrap and private file modes passed"}
        else
          {:error, "repeat bootstrap did not reject without exposing its credential"}
        end
      else
        false -> {:error, "initial diagnostic bootstrap or private file modes failed"}
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp private_mode?(path, type, mode) do
    case File.lstat(path) do
      {:ok, info} -> info.type == type and (info.mode &&& 0o777) == mode
      _ -> false
    end
  end
end

defmodule Mix.Tasks.Woh.Bootstrap.Health.Smoke do
  @moduledoc """
  Exercises one-time diagnostic credential bootstrap in private local state.

  Run `mix woh.bootstrap.health.smoke` to create a temporary Home data directory,
  issue the read-only health credential once, and confirm that a repeat attempt
  fails without exposing that credential. The task checks private Store modes
  and removes the temporary state. It never prints the credential.
  """

  @shortdoc "Smoke-test one-time health bootstrap"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.BootstrapHealthSmoke.run(File.cwd!()) do
      {:ok, message} -> Mix.shell().info(message)
      {:error, reason} -> Mix.raise("health bootstrap smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.bootstrap.health.smoke")
end
