defmodule HomeExternalProfileArchiveTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.ExternalEnvelope

  defp fixture(family) do
    JSON.decode!(File.read!("fixtures/" <> family <> ".json"))
  end

  defp encode(data) do
    {:ok, bytes} = Wotex.JSON.encode(data)
    bytes
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp record(data, reference) do
    bytes = encode(data)
    %{"bytes" => bytes, "raw_sha256" => sha(bytes), "reference" => reference}
  end

  defp inputs(v) do
    producer = %{
      "core_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_CORE_SHA"),
      "runtime_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_RUNTIME_SHA"),
      "profiles_archive_sha256" => System.fetch_env!("WOTEX_HOME_PROFILES_ARCHIVE_SHA")
    }

    documents = %{
      "profile" => record(v["profile"], v["envelope"]["profile"]),
      "definitions" => Enum.zip_with(v["definitions"], v["envelope"]["definitions"], &record/2)
    }

    installed =
      v |> Map.take(~w(bindings contracts home_contracts)) |> Map.put("producer", producer)

    {encode(v["envelope"]), documents, installed}
  end

  defp compile(v) do
    {bytes, documents, installed} = inputs(v)
    ExternalEnvelope.compile(bytes, documents, installed, v["capture"], v["reader_limits"])
  end

  defp resign(v, profile, definitions) do
    refs =
      Enum.map(definitions, fn definition ->
        {:ok, ref} = Wotex.Profiles.Definition.reference(definition, v["reader_limits"])
        ref
      end)

    {:ok, profile_ref} = Wotex.Profiles.Profile.reference(profile, v["reader_limits"])
    envelope = Map.merge(v["envelope"], %{"profile" => profile_ref, "definitions" => refs})
    Map.merge(v, %{"envelope" => envelope, "profile" => profile, "definitions" => definitions})
  end

  test "both independent quantities match frozen byte and projection identities with no routine or Home startup" do
    refute Code.ensure_loaded?(Wotex.Routines)
    refute Code.ensure_loaded?(WotexHome.Application)

    for family <- ~w(temperature research) do
      v = fixture(family)
      {bytes, documents, installed} = inputs(v)
      assert sha(bytes) == v["identities"]["envelope_sha256"]
      assert documents["profile"]["raw_sha256"] == v["identities"]["profile_raw_sha256"]

      assert hd(documents["definitions"])["raw_sha256"] ==
               v["identities"]["definition_raw_sha256"]

      assert installed["producer"] == v["expected"]["producer"]
      assert {:ok, value} = compile(v)
      assert {:ok, summary} = ExternalEnvelope.to_map(value, v["reader_limits"])
      assert summary["projection_sha256"] == v["expected"]["projection_sha256"]
      assert summary["consumption_sha256"] == v["expected"]["consumption_sha256"]
      assert summary["home_contracts"] == v["envelope"]["home_contracts"]
      assert summary["exclusions"] == []
      refute inspect(summary) =~ "synthetic-industrial"
      refute Map.has_key?(summary, "bytes")
      refute Map.has_key?(summary, "capture")

      schema =
        "fixtures/envelope.schema.json"
        |> File.read!()
        |> JSON.decode!()
        |> ExJsonSchema.Schema.resolve()

      assert ExJsonSchema.Validator.valid?(schema, v["envelope"])
    end
  end

  test "raw variant, semantic, capture and forged native replacements cannot keep the old basis" do
    v = fixture("temperature")
    {bytes, documents, installed} = inputs(v)
    changed = put_in(documents, ["profile", "bytes"], documents["profile"]["bytes"] <> " ")

    assert {:error, :stale_external_basis} =
             ExternalEnvelope.compile(bytes, changed, installed, v["capture"], v["reader_limits"])

    changed =
      put_in(
        documents,
        ["definitions", Access.at(0), "reference", "sha256"],
        String.duplicate("0", 64)
      )

    envelope =
      put_in(v["envelope"], ["definitions", Access.at(0), "sha256"], String.duplicate("0", 64))

    assert {:error, :stale_external_basis} =
             ExternalEnvelope.compile(
               encode(envelope),
               changed,
               installed,
               v["capture"],
               v["reader_limits"]
             )

    variant_bytes = documents["profile"]["bytes"] <> " "

    variant_documents =
      documents
      |> put_in(["profile", "bytes"], variant_bytes)
      |> put_in(["profile", "raw_sha256"], sha(variant_bytes))

    assert {:ok, raw_variant} =
             ExternalEnvelope.compile(
               bytes,
               variant_documents,
               installed,
               v["capture"],
               v["reader_limits"]
             )

    assert raw_variant.projection_sha256 == v["expected"]["projection_sha256"]
    refute raw_variant.consumption_sha256 == v["expected"]["consumption_sha256"]

    capture = put_in(v["capture"], ["fields", "model", "value"], "different-model")

    assert {:error, :stale_external_basis} =
             ExternalEnvelope.compile(bytes, documents, installed, capture, v["reader_limits"])

    assert {:ok, value} = compile(v)

    for changed <- [
          %{value | raw_sha256: String.duplicate("0", 64)},
          %{value | consumption_sha256: String.duplicate("0", 64)},
          %{value | data: %{}},
          %{value | documents: documents |> put_in(["profile", "bytes"], "{}")},
          %{value | inputs: %{}},
          Map.put(value, :extra, "private-canary")
        ] do
      assert {:error, code} = ExternalEnvelope.to_map(changed, v["reader_limits"])
      assert code in [:stale_external_basis, :invalid_external_closure]
    end

    assert {:error, :stale_external_basis} =
             ExternalEnvelope.to_map(value, Map.put(v["reader_limits"], "max_nodes", 4095))
  end

  test "missing or uninstalled consumption fails; an optional channel is an explicit exclusion" do
    v = fixture("temperature")

    assert {:error, :unsupported_external_profile} =
             compile(put_in(v, ["envelope", "home_contracts"], []))

    assert {:error, :unsupported_external_profile} = compile(Map.put(v, "home_contracts", []))
    unknown = put_in(v, ["envelope", "home_contracts", Access.at(0), "channel_id"], "absent")
    assert {:error, :unsupported_external_profile} = compile(unknown)
    [first] = v["profile"]["channels"]
    optional = Map.merge(first, %{"id" => "secondary", "required" => false})
    profile = Map.put(v["profile"], "channels", [first, optional])
    v = resign(v, profile, v["definitions"])
    assert {:ok, value} = compile(v)
    assert {:ok, summary} = ExternalEnvelope.to_map(value, v["reader_limits"])

    assert summary["exclusions"] == [
             %{"channel_id" => "secondary", "reason" => "consumption_unavailable"}
           ]

    profile = put_in(profile, ["channels", Access.at(1), "required"], true)
    assert {:error, :unsupported_external_profile} = compile(resign(v, profile, v["definitions"]))
  end

  test "producer-unsupported optional operations stay excluded and required writes refuse" do
    v = fixture("temperature")
    [first] = v["profile"]["channels"]

    optional =
      Map.merge(first, %{
        "id" => "secondary",
        "required" => false,
        "operations" => ["writeproperty"]
      })

    profile = Map.put(v["profile"], "channels", [first, optional])
    v = resign(v, profile, v["definitions"])
    assert {:ok, value} = compile(v)
    assert {:ok, summary} = ExternalEnvelope.to_map(value, v["reader_limits"])

    assert summary["exclusions"] == [
             %{"channel_id" => "secondary", "reason" => "producer_unsupported"}
           ]

    profile = put_in(profile, ["channels", Access.at(1), "required"], true)
    assert {:error, :unsupported_external_profile} = compile(resign(v, profile, v["definitions"]))
  end

  test "Home excludes producer-supported writes and refuses their required use" do
    v = fixture("temperature")
    [binding] = v["bindings"]

    unsigned =
      binding |> Map.delete("sha256") |> Map.put("operations", ["readproperty", "writeproperty"])

    {:ok, digest} = Wotex.Profiles.Binding.digest(unsigned, v["reader_limits"])
    binding = Map.put(unsigned, "sha256", digest)
    {:ok, ref} = Wotex.Profiles.Binding.reference(binding, v["reader_limits"])
    capture = v["capture"] |> Map.delete("digest") |> Map.put("binding", ref)
    {:ok, digest} = Wotex.Profiles.Capture.digest(capture, binding, v["reader_limits"])
    v = Map.merge(v, %{"bindings" => [binding], "capture" => Map.put(capture, "digest", digest)})
    [first] = v["profile"]["channels"]

    optional =
      Map.merge(first, %{
        "id" => "secondary",
        "required" => false,
        "operations" => ["writeproperty"]
      })

    profile = Map.merge(v["profile"], %{"binding" => ref, "channels" => [first, optional]})
    v = resign(v, profile, v["definitions"])
    assert {:ok, value} = compile(v)
    assert {:ok, summary} = ExternalEnvelope.to_map(value, v["reader_limits"])

    assert summary["exclusions"] == [
             %{"channel_id" => "secondary", "reason" => "operation_unsupported"}
           ]

    profile = put_in(profile, ["channels", Access.at(1), "required"], true)
    assert {:error, :unsupported_external_profile} = compile(resign(v, profile, v["definitions"]))
  end

  test "unreachable or missing selected definitions do not become accepted custody closure" do
    v = fixture("temperature")
    extra = Map.put(hd(v["definitions"]), "id", "urn:example:semantic:unreachable")
    definitions = v["definitions"] ++ [extra]
    assert {:error, :invalid_external_closure} = compile(resign(v, v["profile"], definitions))
    assert {:error, :unsupported_external_profile} = compile(resign(v, v["profile"], []))
  end

  test "bounded malformed closures and producer registrations never retain payloads" do
    v = fixture("temperature")
    {bytes, documents, installed} = inputs(v)

    for bad <- [
          Map.put(documents, "definitions", [hd(documents["definitions"]) | :bad]),
          %URI{},
          Map.put(documents, "private-canary", "secret-canary"),
          Map.put(documents, "definitions", []),
          put_in(documents, ["profile", "bytes"], String.duplicate("x", 65_537)),
          put_in(documents, ["profile", "reference"], %{})
        ] do
      assert {:error, code} =
               ExternalEnvelope.compile(bytes, bad, installed, v["capture"], v["reader_limits"])

      refute inspect(code) =~ "canary"
    end

    for bad <- [
          %URI{},
          Map.put(installed, "private-canary", "secret-canary"),
          Map.put(installed, "bindings", []),
          put_in(installed, ["producer", "profiles_archive_sha256"], "bad")
        ] do
      assert {:error, code} =
               ExternalEnvelope.compile(bytes, documents, bad, v["capture"], v["reader_limits"])

      refute inspect(code) =~ "canary"
    end

    assert {:error, :external_profile_limit} =
             ExternalEnvelope.compile(
               bytes,
               documents,
               installed,
               v["capture"],
               Map.put(v["reader_limits"], "max_bytes", 128)
             )

    assert {:error, :invalid_external_closure} =
             ExternalEnvelope.to_map(%URI{}, v["reader_limits"])
  end
end
