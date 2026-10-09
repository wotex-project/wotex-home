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

  def verify_units(_root, options \\ []) do
    change = Keyword.get(options, :change, &mutation/2)

    change.("/usr/bin/systemd-analyze", [
      "--man=no",
      "verify",
      "/etc/systemd/system/wotex-home.service",
      "/etc/systemd/system/run-wotexhomejournal.mount",
      "/usr/lib/systemd/system/systemd-journald@wotex-home.service"
    ])
  end

  def reload(options \\ []) do
    change = Keyword.get(options, :change, &mutation/2)
    change.("/usr/bin/systemctl", ["--system", "daemon-reload"])
  end

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

  def effective_units(query \\ &Command.run/4) do
    checks = [
      {"wotex-home.service", "/etc/systemd/system/wotex-home.service", ""},
      {"run-wotexhomejournal.mount", "/etc/systemd/system/run-wotexhomejournal.mount", ""},
      {"systemd-journald@wotex-home.service", "/usr/lib/systemd/system/systemd-journald@.service",
       "/etc/systemd/system/systemd-journald@wotex-home.service.d/home-budget.conf"}
    ]

    Enum.reduce_while(checks, :ok, fn {unit, fragment, dropin}, :ok ->
      with {:ok, output} <-
             query.(
               "/usr/bin/systemctl",
               [
                 "--system",
                 "show",
                 "--all",
                 "--no-pager",
                 "--property=FragmentPath,DropInPaths",
                 unit
               ],
               8192,
               5000
             ),
           {:ok, fields} <- fields(output, ~w(FragmentPath DropInPaths)),
           true <- fields == %{"FragmentPath" => fragment, "DropInPaths" => dropin} do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "effective Home unit or drop-ins differ"}}
      end
    end)
  end

  # Read-only observations and mutation overrides serve private fixtures only.
  # The CLI does not expose them. Process image, kernel socket peer, cgroup and
  # original maintenance-barrier joins belong to the update coordinator.
  def controller_status(query \\ &Command.run/4) do
    with {:ok, output} <-
           query.(
             "/usr/bin/systemctl",
             [
               "--system",
               "show",
               "--all",
               "--no-pager",
               "--property=LoadState,ActiveState,SubState,MainPID,ControlPID,FragmentPath,DropInPaths",
               "wotex-home.service"
             ],
             4096,
             5000
           ),
         {:ok, status} <- decode_controller_status(output) do
      {:ok, status}
    else
      _ -> {:error, "Home controller status unavailable or changed"}
    end
  end

  def decode_controller_status(output) do
    with {:ok, values} <-
           fields(
             output,
             ~w(LoadState ActiveState SubState MainPID ControlPID FragmentPath DropInPaths)
           ),
         "loaded" <- values["LoadState"],
         "/etc/systemd/system/wotex-home.service" <- values["FragmentPath"],
         "" <- values["DropInPaths"],
         "0" <- values["ControlPID"] do
      case {values["ActiveState"], values["SubState"], values["MainPID"]} do
        {"inactive", "dead", "0"} ->
          {:ok, %{state: :stopped, pid: 0}}

        {"active", "running", text} ->
          with true <- is_binary(text) and text =~ ~r/\A[1-9][0-9]{0,9}\z/,
               {pid, ""} <- Integer.parse(text),
               true <- pid in 2..2_147_483_647 do
            {:ok, %{state: :running, pid: pid}}
          else
            _ -> {:error, "Home controller status unavailable or changed"}
          end

        _ ->
          {:error, "Home controller status unavailable or changed"}
      end
    else
      _ -> {:error, "Home controller status unavailable or changed"}
    end
  end

  # A stable PID alone does not identify a service incarnation. The coordinator
  # joins this closed registration with independently read kernel observations.
  def controller_registration(query \\ &Command.run/4) do
    keys =
      ~w(LoadState ActiveState SubState MainPID ControlPID FragmentPath DropInPaths ControlGroup InvocationID)

    with {:ok, output} <-
           query.(
             "/usr/bin/systemctl",
             [
               "--system",
               "show",
               "--all",
               "--no-pager",
               "--property=" <> Enum.join(keys, ","),
               "wotex-home.service"
             ],
             4096,
             5000
           ),
         {:ok, values} <- fields(output, keys),
         status_bytes =
           Enum.map_join(Enum.take(keys, 7), "", &(&1 <> "=" <> values[&1] <> "\n")),
         {:ok, status} <- decode_controller_status(status_bytes),
         true <- registration?(status, values) do
      {:ok,
       Map.merge(status, %{cgroup: values["ControlGroup"], invocation_id: values["InvocationID"]})}
    else
      _ -> {:error, :invalid_controller_registration}
    end
  end

  defp registration?(%{state: :running}, values),
    do:
      values["ControlGroup"] == "/system.slice/wotex-home.service" and
        invocation?(values["InvocationID"])

  defp registration?(%{state: :stopped}, values),
    do:
      values["ControlGroup"] in ["", "/system.slice/wotex-home.service"] and
        (values["InvocationID"] == "" or invocation?(values["InvocationID"]))

  defp invocation?(value),
    do: Regex.match?(~r/\A[0-9a-f]{32}\z/, value) and value != String.duplicate("0", 32)

  def stop_controller(expected_pid, options \\ [])

  def stop_controller(expected_pid, options) when expected_pid in 2..2_147_483_647 do
    query = Keyword.get(options, :query, &Command.run/4)
    change = Keyword.get(options, :change, &mutation/2)

    case controller_status(query) do
      {:ok, %{state: :stopped, pid: 0}} ->
        :ok

      {:ok, %{state: :running, pid: ^expected_pid}} ->
        with :ok <- change.("/usr/bin/systemctl", ["--system", "stop", "wotex-home.service"]),
             {:ok, %{state: :stopped, pid: 0}} <- controller_status(query) do
          :ok
        else
          _ -> {:error, "Home controller stop unconfirmed"}
        end

      _ ->
        {:error, "Home controller changed before stop"}
    end
  end

  def stop_controller(_, _), do: {:error, "invalid original controller PID"}

  def start_controller(options \\ []) do
    query = Keyword.get(options, :query, &Command.run/4)
    change = Keyword.get(options, :change, &mutation/2)

    with {:ok, %{state: :stopped, pid: 0}} <- controller_status(query),
         :ok <- change.("/usr/bin/systemctl", ["--system", "start", "wotex-home.service"]),
         {:ok, %{state: :running, pid: pid}} <- controller_status(query) do
      {:ok, pid}
    else
      _ -> {:error, "Home controller start unconfirmed"}
    end
  end

  defp fields(bytes, keys) when is_binary(bytes) and byte_size(bytes) <= 8192 do
    with ["" | reversed] <- bytes |> String.split("\n") |> Enum.reverse(),
         rows = Enum.reverse(reversed),
         true <- length(rows) == length(keys),
         pairs = Enum.map(rows, &String.split(&1, "=", parts: 2)),
         true <- Enum.all?(pairs, &match?([_, _], &1)),
         true <- Enum.sort(Enum.map(pairs, &hd/1)) == Enum.sort(keys) do
      {:ok, Map.new(pairs, fn [key, value] -> {key, value} end)}
    else
      _ -> {:error, :invalid_unit_properties}
    end
  end

  defp fields(_, _), do: {:error, :invalid_unit_properties}

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
