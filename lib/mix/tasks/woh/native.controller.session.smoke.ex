defmodule Mix.Tasks.Woh.Native.Controller.Session.Smoke do
  @moduledoc "Checks the shared selection owner with a real private foreground Store, metadata CAS and remote no-fallback. It creates no signed paired seal."
  @shortdoc "Check shared controller selection and reads"
  @requirements ["loadpaths"]
  use Mix.Task
  alias Woh.Tool.Command
  alias WotexHome.{Authority, Durable.Store}
  alias WotexHome.LocalAPI.Server
  alias WotexHome.Semantics.Thing

  def run([]) do
    root =
      directory("/private/tmp", "woh-controller-session-#{System.unique_integer([:positive])}")

    executable = Path.join(root, "session-driver")
    metadata = directory(root, "metadata")
    journal = directory(root, "journal")
    socket = Path.join(root, "home.sock")
    {:ok, store} = Store.start_link(path: Path.join(root, "home.sqlite"))
    {:ok, thing} = thing()
    {:ok, 1} = Store.enroll_thing(store, thing)

    {:ok, credential, 2} =
      Store.provision_principal(store, "operator:session-fixture", ~w(read control:ordinary), [
        thing.id
      ])

    {:ok, server} = Server.start_link(authority: Authority.new(store: store), socket_path: socket)

    try do
      sources =
        Path.wildcard(Path.expand("native/macos/Sources/*.swift"))
        |> Enum.reject(&(Path.basename(&1) == "WotexHomeApp.swift"))

      args =
        [
          "-parse-as-library",
          "-warnings-as-errors",
          "-swift-version",
          "6",
          "-target",
          "arm64-apple-macos15.0",
          "-module-cache-path",
          Path.join(root, "cache")
        ] ++
          Enum.flat_map(
            ~w(SwiftUI AppKit Security LocalAuthentication CryptoKit ServiceManagement),
            &["-framework", &1]
          ) ++
          sources ++
          [
            Path.expand("native/macos/Tests/NativeControllerSessionDriverSmoke.swift"),
            "-o",
            executable
          ]

      with {:ok, _} <- Command.run_diagnostic("swiftc", args, 1_048_576, 180_000),
           {:ok, output} <-
             Command.run_diagnostic(
               executable,
               [
                 socket,
                 metadata,
                 journal,
                 Path.expand("test/fixtures/controller_connections/native_associations_v1.json")
               ],
               16_384,
               30_000,
               Base.url_encode64(credential, padding: false) <> "\n"
             ),
           true <-
             String.trim(output) ==
               "native shared controller selection, real local reads, original recovery, CAS and remote no-fallback passed" do
        preview = Path.expand("_build/native/controller-selection.png")
        File.mkdir_p!(Path.dirname(preview))
        File.cp!(Path.join(journal, "selection.png"), preview)
        Mix.shell().info(String.trim(output))
      else
        {:error, reason} -> Mix.raise("native controller session smoke failed: #{reason}")
        _ -> Mix.raise("native controller session fixture did not complete")
      end
    after
      for pid <- [server, store], Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp thing do
    Thing.new(%{
      "id" => "light:session-fixture",
      "role" => "Light",
      "profile_ref" => "fixture:session:1",
      "capabilities" => [
        %{
          "thing_id" => "light:session-fixture",
          "role" => "Light",
          "key" => "power",
          "value_kind" => "boolean",
          "unit" => "none",
          "operations" => ["read", "write"],
          "risk_class" => "ordinary",
          "profile_ref" => "fixture:session:1",
          "evidence_ref" => "fixture:session",
          "freshness_ms" => 5_000,
          "constraints" => %{},
          "extensions" => %{}
        }
      ]
    })
  end

  defp directory(parent, name) do
    path = Path.join(parent, name)
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end
