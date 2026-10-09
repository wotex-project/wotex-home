defmodule Woh.Tool.LinuxInstallHost do
  @moduledoc false
  alias Woh.Tool.{Command, LinuxInstallFiles, LinuxInstallPreflight}

  def snapshot, do: LinuxInstallPreflight.snapshot()

  def choose_account_id do
    with {:ok, passwd} <- read("/etc/passwd"), {:ok, group} <- read("/etc/group") do
      choose_account_id(passwd, group, &resolve_id/2)
    end
  end

  # The lookup override is for pure namespace-failure probes, never the CLI.
  # At most 16 locally free IDs cause NSS queries; an unavailable resolver
  # stops immediately rather than silently looking like an occupied ID.
  def choose_account_id(passwd, group, lookup) do
    occupied =
      for line <- String.split(passwd <> "\n" <> group, "\n", trim: true),
          fields = String.split(line, ":"),
          length(fields) >= 3,
          {id, ""} <- [Integer.parse(Enum.at(fields, 2))],
          into: MapSet.new(),
          do: id

    100..999
    |> Enum.reject(&MapSet.member?(occupied, &1))
    |> Enum.take(16)
    |> Enum.reduce_while({:error, "no free ID within bounded account lookup"}, fn id, error ->
      with {:ok, user} <- lookup.("passwd", to_string(id)),
           {:ok, group} <- lookup.("group", to_string(id)) do
        if user == :absent and group == :absent,
          do: {:halt, {:ok, id}},
          else: {:cont, error}
      else
        _ -> {:halt, {:error, "system account resolver unavailable"}}
      end
    end)
  end

  def accounts(id, installation) do
    with {:ok, passwd} <- read("/etc/passwd"), {:ok, group} <- read("/etc/group") do
      users = rows(passwd, "wotex-home")
      groups = rows(group, "wotex-home")
      wanted_group = ["wotex-home", "x", to_string(id), ""]

      wanted_user = [
        "wotex-home",
        "x",
        to_string(id),
        to_string(id),
        comment(installation),
        "/var/lib/wotex-home",
        "/usr/sbin/nologin"
      ]

      cond do
        users == [] and groups == [] and absent?("passwd", "wotex-home") and
            absent?("group", "wotex-home") ->
          {:ok, :absent}

        users == [] and groups == [wanted_group] and lookup?("group", wanted_group) and
            absent?("passwd", "wotex-home") ->
          {:ok, :group_only}

        users == [wanted_user] and groups == [wanted_group] and lookup?("passwd", wanted_user) and
            lookup?("group", wanted_group) ->
          with {:ok, shadow} <- read("/etc/shadow") do
            case rows(shadow, "wotex-home") do
              [[_, password | _]] ->
                if String.starts_with?(password, ["!", "*"]),
                  do: {:ok, :ready},
                  else: {:error, "Home account password is not locked"}

              _ ->
                {:error, "Home shadow account differs"}
            end
          end

        true ->
          {:error, "Home account or group differs from recorded ownership"}
      end
    end
  end

  def create_group(id),
    do: mutation("/usr/sbin/groupadd", ["--system", "--gid", to_string(id), "wotex-home"])

  def create_user(id, installation),
    do:
      mutation("/usr/sbin/useradd", [
        "--system",
        "--uid",
        to_string(id),
        "--gid",
        to_string(id),
        "--no-user-group",
        "--no-create-home",
        "--no-log-init",
        "--home-dir",
        "/var/lib/wotex-home",
        "--shell",
        "/usr/sbin/nologin",
        "--comment",
        comment(installation),
        "wotex-home"
      ])

  def verify_units(_root) do
    mutation("/usr/bin/systemd-analyze", [
      "--man=no",
      "verify",
      "/etc/systemd/system/wotex-home.service",
      "/etc/systemd/system/run-wotexhomejournal.mount",
      "/usr/lib/systemd/system/systemd-journald@wotex-home.service"
    ])
  end

  def reload, do: mutation("/usr/bin/systemctl", ["--system", "daemon-reload"])

  def enable_start,
    do:
      mutation("/usr/bin/systemctl", ["--system", "enable", "--now", "wotex-home.service"], false)

  def disable_stop do
    with :ok <-
           if(File.lstat("/etc/systemd/system/wotex-home.service") == {:error, :enoent},
             do: :ok,
             else:
               mutation(
                 "/usr/bin/systemctl",
                 ["--system", "disable", "wotex-home.service"],
                 false
               )
           ) do
      stop_loaded(["wotex-home.service"])
    end
  end

  def stop_journal,
    do: stop_loaded(["systemd-journald@wotex-home.service", "run-wotexhomejournal.mount"])

  defp stop_loaded(names) do
    with {:ok, output} <-
           Command.run(
             "/usr/bin/systemctl",
             [
               "--system",
               "--no-pager",
               "--no-legend",
               "--plain",
               "--full",
               "list-units",
               "--all" | names
             ],
             8192,
             5000
           ) do
      loaded =
        String.split(output, "\n", trim: true) |> Enum.map(&(String.split(&1) |> List.first()))

      if Enum.all?(loaded, &(&1 in names)) do
        if loaded == [],
          do: :ok,
          else: mutation("/usr/bin/systemctl", ["--system", "stop" | loaded])
      else
        {:error, "loaded unit namespace differs"}
      end
    end
  end

  def effective_units do
    checks = [
      {"wotex-home.service", "/etc/systemd/system/wotex-home.service", ""},
      {"run-wotexhomejournal.mount", "/etc/systemd/system/run-wotexhomejournal.mount", ""},
      {"systemd-journald@wotex-home.service", "/usr/lib/systemd/system/systemd-journald@.service",
       "/etc/systemd/system/systemd-journald@wotex-home.service.d/home-budget.conf"}
    ]

    Enum.reduce_while(checks, :ok, fn {unit, fragment, dropin}, :ok ->
      with {:ok, output} <-
             Command.run(
               "/usr/bin/systemctl",
               ["--system", "show", "--no-pager", "--property=FragmentPath,DropInPaths", unit],
               8192,
               5000
             ),
           fields =
             Map.new(String.split(output, "\n", trim: true), fn row ->
               [key, value] = String.split(row, "=", parts: 2)
               {key, value}
             end),
           true <- fields == %{"FragmentPath" => fragment, "DropInPaths" => dropin} do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "effective Home unit or drop-ins differ"}}
      end
    end)
  end

  def running do
    case Command.run(
           "/usr/bin/systemctl",
           ["--system", "is-active", "wotex-home.service"],
           128,
           5000
         ) do
      {:ok, "active\n"} -> :ok
      _ -> {:error, "Home service is registered but not active"}
    end
  end

  defp mutation(path, args, empty \\ true) do
    case LinuxInstallFiles.execute(path, args) do
      {:ok, output} when not empty or output == "" -> :ok
      {:ok, _} -> {:error, "installer tool reported diagnostics"}
      {:error, _} = error -> error
    end
  end

  defp comment(id), do: "WoTEx Home installation " <> id

  defp rows(bytes, name),
    do:
      bytes
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, ":"))
      |> Enum.filter(&(hd(&1) == name))

  defp absent?(database, name),
    do:
      Command.run("/usr/bin/getent", [database, name], 8192, 5000) ==
        {:error, "tool exited with status 2"}

  defp resolve_id(database, name) do
    case Command.run("/usr/bin/getent", [database, name], 8192, 5000) do
      {:error, "tool exited with status 2"} -> {:ok, :absent}
      {:ok, _} -> {:ok, :present}
      _ -> {:error, "account resolver unavailable"}
    end
  end

  defp lookup?(database, row),
    do:
      Command.run("/usr/bin/getent", [database, hd(row)], 8192, 5000) ==
        {:ok, Enum.join(row, ":") <> "\n"}

  defp read(path) do
    with {:ok, bytes} <- File.open(path, [:read, :binary], &IO.binread(&1, 1_048_577)),
         true <- is_binary(bytes) and byte_size(bytes) <= 1_048_576 do
      {:ok, bytes}
    else
      _ -> {:error, "local account database unavailable or overlong"}
    end
  end
end
