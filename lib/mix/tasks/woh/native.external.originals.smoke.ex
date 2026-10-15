defmodule Mix.Tasks.Woh.Native.External.Originals.Smoke do
  @moduledoc """
  Checks complete native external-profile originals against independent bytes.

  Run `mix woh.native.external.originals.smoke` on the supported macOS toolchain.
  The frozen Python corpus checks exact inspection/trust/target bytes and SHA,
  complete native fields, references/actions, bounded preflight and refusals.
  The task also compares every accepted original and malformed native map with
  the actual Elixir owning codec. It performs no Store, source, credential or
  network work; successful encoding establishes no permission or qualification.
  """

  use Mix.Task
  alias Woh.Tool.{Command, NativeFixture}
  @requirements ["loadpaths"]
  @shortdoc "Check native external profile original codecs and owning parity"
  def run([]) do
    path = Path.expand("test/fixtures/profiles/native-external-profile-originals-v1.json")
    corpus = JSON.decode!(File.read!(path))

    for vector <- corpus["valid"] do
      codec = codec(vector["kind"])
      {:ok, document} = codec.encode(vector["input"])
      true = document == vector["document"]
      {:ok, input} = codec.decode(document)
      true = input == vector["input"]
    end

    for vector <- corpus["invalid"] do
      {:error, _} = codec(vector["kind"]).encode(vector["input"])
    end

    for vector <- corpus["invalid_wire"] do
      {:error, _} = codec(vector["kind"]).decode(Base.decode64!(vector["payload_base64"]))
    end

    root = Path.join("/private/tmp", "external-originals-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "originals")

    try do
      uris = uri_cases()
      parity = Path.join(root, "uri-cases.json")
      File.write!(parity, JSON.encode!(uris))
      File.chmod!(parity, 0o600)

      with :ok <-
             NativeFixture.compile(
               File.cwd!(),
               "NativeExternalProfileOriginalSmoke.swift",
               executable,
               ["NativeExternalProfileClient", "NativeExternalProfileOriginalWire"]
             ),
           {:ok, _} <- Command.run_diagnostic(executable, [path], 16_384, 15_000),
           {:ok, _} <-
             Command.run_diagnostic(executable, ["--uri-parity", parity], 16_384, 15_000),
           do:
             Mix.shell().info(
               "native external originals and Elixir owners passed 281 frozen cases and #{length(uris)} URI parity cases"
             ),
           else: ({:error, reason} -> Mix.raise("native external originals failed: #{reason}"))
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.external.originals.smoke")

  defp uri_cases do
    base =
      JSON.decode!(File.read!("test/fixtures/profiles/external-inspections.json"))["temperature"][
        "input"
      ]

    authority =
      for host <- [
            "",
            "h",
            "h%ZZ",
            "127.999.1.1",
            "[::1]",
            "[::1]abc",
            "[::1].",
            "[v1.a]",
            "[bad]",
            "h[a]"
          ],
          port <- ["", ":", ":0", ":99999", ":100000", ":000001"],
          user <- ["", "u:p@", "a@b@"],
          suffix <- ["", "/p", "/p?q=a#f"],
          do: "x://" <> user <> host <> port <> suffix

    components =
      for prefix <- ["urn:p", "urn:p?q=", "urn:p#"],
          char <- ["a", ":", "@", "%", "!", "[", "]", "|", "?", "#", "\\", " ", "λ"],
          do: prefix <> char <> "q"

    for uri <- Enum.uniq(authority ++ components) do
      input = put_in(base, ["inspection", "profile", "reference", "id"], uri)

      document =
        case WotexHome.Profiles.ExternalInspection.encode(input) do
          {:ok, document} -> document
          {:error, _} -> nil
        end

      %{"input" => input, "document" => document}
    end
  end

  defp codec("inspection"), do: WotexHome.Profiles.ExternalInspection
  defp codec("trust"), do: WotexHome.Profiles.ExternalTrust
  defp codec("target"), do: WotexHome.Profiles.ExternalTarget
end
