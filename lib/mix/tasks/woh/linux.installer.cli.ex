defmodule Woh.Tool.LinuxInstallerCLI do
  @moduledoc false

  def main do
    action =
      case System.fetch_env!("WOTEX_HOME_INSTALL_ACTION") do
        "install" -> :install
        "uninstall" -> :uninstall
        "update" -> :update
        _ -> raise "invalid installer action"
      end

    unless System.get_env("WOTEX_HOME_INSTALL_LOCK_PATH") == "/run/wotex-home-installer.lock",
      do: raise("fixed installer lock missing")

    fd = System.fetch_env!("WOTEX_HOME_INSTALL_LOCK_FD")
    unless Regex.match?(~r/\A[0-9]{1,5}\z/, fd), do: raise("invalid installer lock descriptor")
    held = File.stat!("/proc/self/fd/" <> fd)
    named = File.lstat!("/run/wotex-home-installer.lock")

    unless held.type == :regular and held.uid == 0 and held.links == 1 and
             held.inode == named.inode and held.major_device == named.major_device,
           do: raise("installer lock descriptor or path changed")

    result =
      if action == :update do
        with {:ok, credential} <- Woh.Tool.LinuxUpdateCredential.read(),
             {:ok, result} <-
               Woh.Tool.LinuxUpdate.run(
                 System.fetch_env!("WOTEX_HOME_INSTALL_RELEASE"),
                 System.fetch_env!("WOTEX_HOME_INSTALL_MANIFEST"),
                 System.fetch_env!("WOTEX_HOME_INSTALL_PIN"),
                 credential
               ) do
          {:ok,
           %{
             "artifact_id" => result.intent["target"]["artifact_id"],
             "source_revision" => result.intent["target"]["source_revision"],
             "phase" => result.intent["phase"],
             "maintenance" => "retained"
           }}
        else
          {:error, reason} -> {:error, Atom.to_string(reason)}
        end
      else
        Woh.Tool.LinuxInstaller.run(
          action,
          System.fetch_env!("WOTEX_HOME_INSTALL_RELEASE"),
          System.fetch_env!("WOTEX_HOME_INSTALL_MANIFEST"),
          System.fetch_env!("WOTEX_HOME_INSTALL_PIN")
        )
      end

    case result do
      {:ok, result} ->
        IO.puts(JSON.encode!(result))

      {:error, reason} ->
        label =
          if action == :update, do: "release update refused: ", else: "installation refused: "

        IO.puts(:stderr, label <> reason)
        System.halt(1)
    end
  end
end
