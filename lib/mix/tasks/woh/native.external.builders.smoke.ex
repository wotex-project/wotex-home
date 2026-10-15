defmodule Mix.Tasks.Woh.Native.External.Builders.Smoke do
  @moduledoc """
  Checks pure native external-profile builders against independent original bytes.

  Run from the repository root with Python 3 and an Apple Silicon macOS Swift 6
  toolchain targeting macOS 15:

      mix woh.native.external.builders.smoke
      mix woh.native.external.builders.smoke --live

  The default run checks the frozen corpus against its Python oracle, round-trips
  valid documents through `WotexHome.Profiles.ExternalInspection`,
  `WotexHome.Profiles.ExternalTrust` and `WotexHome.Profiles.ExternalTarget`, then
  compiles and runs the Swift fixture. It compares constructed inputs, canonical
  documents and SHA-256 digests for inspection, trust approval/revocation and
  target selection/revocation. Rejection cases cover object references and
  malformed, stale or unavailable comparison metadata.

  `--live` additionally constructs and consumes all five decisions through
  `WotexHome.Authority` and disposable `WotexHome.Durable.Store` instances for
  both temperature and research fixture families. It checks that construction
  preserves Store revisions and custody leases, that exact status reads preserve
  revisions, and that revocations work after the reader/source owner is removed.

  The Swift builder receives snapshot data and object references, without a
  credential or socket. Its output requires the application's current authority
  checks when submitted; construction grants no approval or target selection.
  These are software fixture checks, not installed signing or physical-device
  qualification. Success reports the corpus case count and whether live Store
  consumption ran.
  """

  use Mix.Task
  alias Woh.Tool.{Command, NativeFixture, NativeExternalBuilderLive}
  @shortdoc "Check pure native external profile decision construction"
  @requirements ["loadpaths"]

  def run(args) when args in [[], ["--live"]] do
    root = Path.join("/private/tmp", "external-builders-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "builders")
    path = Path.expand("test/fixtures/profiles/native-external-profile-builders-v1.json")
    corpus = JSON.decode!(File.read!(path))

    for vector <- corpus["valid"] do
      {:ok, document} = codec(vector["kind"]).encode(vector["expected"])
      true = document == vector["document"]
      {:ok, fields} = codec(vector["kind"]).decode(document)
      true = fields == vector["expected"]
    end

    try do
      with {:ok, _} <-
             Command.run_diagnostic(
               "python3",
               ["test/support/native_external_profile_builders_oracle.py", "--check"],
               16_384,
               10_000
             ),
           :ok <-
             NativeFixture.compile(
               File.cwd!(),
               "NativeExternalProfileBuilderSmoke.swift",
               executable,
               [
                 "NativeExternalProfileClient",
                 "NativeExternalProfileOriginalWire",
                 "NativeExternalGuidanceClient",
                 "NativeExternalProfileBuilder"
               ]
             ),
           {:ok, _} <- Command.run_diagnostic(executable, [path], 16_384, 15_000),
           :ok <-
             if(args == ["--live"],
               do: NativeExternalBuilderLive.run(executable, root),
               else: :ok
             ) do
        count =
          Enum.sum(
            Enum.map(
              ~w(valid invalid objects_valid objects_invalid objects_wire_invalid),
              &length(corpus[&1])
            )
          )

        Mix.shell().info(
          "native external builders passed #{count} independent cases#{if args == ["--live"], do: " and both-family Store consumption", else: ""}"
        )
      else
        {:error, reason} -> Mix.raise("native external builders failed: #{reason}")
      end
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.external.builders.smoke [--live]")
  defp codec("inspection"), do: WotexHome.Profiles.ExternalInspection
  defp codec("trust"), do: WotexHome.Profiles.ExternalTrust
  defp codec("target"), do: WotexHome.Profiles.ExternalTarget
end
