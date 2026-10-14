defmodule WotexHome.InstalledProfileRuntimeTest do
  use ExUnit.Case, async: false
  alias WotexHome.Host.ProfileInstallation
  alias WotexHome.Profiles.{AuthoringContract, EnvelopeSummary, ProducerIdentity, ReaderSelection}

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp config(family, publisher \\ self()) do
    v = fixture(family)

    %{
      installed: Map.take(v, ~w(bindings contracts home_contracts)),
      capture: v["capture"],
      reader_limits: v["reader_limits"],
      authoring_limits: fixture("authoring-mechanics")[family]["limits"],
      publisher: publisher
    }
  end

  test "runtime identity uses real per-application inventories and both historical wire shapes" do
    assert {:ok, runtime} = ProducerIdentity.current()
    assert runtime["source_revision"] == WotexHome.MixProject.source_pins()[:wotex]

    for {key, app} <- [
          {"core_runtime_sha256", :wotex},
          {"runtime_runtime_sha256", :wotex_runtime},
          {"profiles_runtime_sha256", :wotex_profiles}
        ] do
      assert {:ok, digest} =
               WotexHome.RuntimeArtifacts.digest([app], "wotex-home.profile-producer-runtime@1")

      assert runtime[key] == digest
    end

    assert :ok = ProducerIdentity.check_current(runtime)
    archive = fixture("temperature")["expected"]["producer"]

    for producer <- [runtime, archive] do
      assert ProducerIdentity.valid?(producer)
      assert {:ok, ^producer} = ProducerIdentity.from_wire(ProducerIdentity.values(producer))
      summary = fixture("external-inspections")["temperature"]["result"]["envelope"]
      summary = Map.put(summary, "producer", producer)
      assert EnvelopeSummary.valid?(summary)
      assert {:ok, ^summary} = EnvelopeSummary.from_wire(EnvelopeSummary.values(summary))
    end

    assert ProducerIdentity.values(archive) ==
             Enum.map(
               ~w(core_archive_sha256 runtime_archive_sha256 profiles_archive_sha256),
               &archive[&1]
             )

    for bad <- [
          Map.merge(runtime, archive),
          Map.put(runtime, "extra", true),
          Map.put(runtime, "source_revision", String.duplicate("a", 40)),
          Map.put(runtime, "format", "unknown"),
          Map.put(runtime, "core_runtime_sha256", String.duplicate("A", 64)),
          %ReaderSelection{inputs: %{}, data: %{}}
        ] do
      refute ProducerIdentity.valid?(bad)
    end

    assert {:error, :invalid_profile_producer} = ProducerIdentity.from_wire(["bad", "bad", "bad"])
    changed = Map.put(runtime, "core_runtime_sha256", String.duplicate("0", 64))
    assert ProducerIdentity.valid?(changed)
    assert {:error, :stale_profile_runtime} = ProducerIdentity.check_current(changed)
  end

  test "two independent families install actual runtime basis and reject forged current assertions" do
    assert {:ok, nil} = ProfileInstallation.prepare(nil)

    for family <- ~w(temperature research) do
      input = config(family)
      assert {:ok, prepared} = ProfileInstallation.prepare(input)
      assert {:ok, reader} = ReaderSelection.to_map(prepared.reader)
      assert {:ok, authoring} = AuthoringContract.to_map(prepared.authoring)
      assert reader["producer"] == authoring["producer"]

      assert authoring["contract_sha256"] ==
               fixture("authoring-mechanics")[family]["contract_sha256"]

      refute Map.has_key?(reader["producer"], "core_archive_sha256")

      installed = prepared.reader.inputs["installed"]
      changed = put_in(installed, ["producer", "core_runtime_sha256"], String.duplicate("0", 64))

      assert {:error, :stale_profile_runtime} =
               ReaderSelection.new(changed, input.capture, input.reader_limits)

      assert {:error, :stale_profile_runtime} =
               AuthoringContract.export(changed, input.authoring_limits)
    end
  end

  test "invalid host installation refuses before acquiring any private resource" do
    directory =
      Path.join(System.tmp_dir!(), "home-invalid-profile-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)
    input = config("temperature")

    for bad <- [
          %{},
          Map.put(input, :extra, true),
          Map.put(input, :publisher, nil),
          put_in(input, [:installed, "producer"], %{}),
          put_in(input, [:authoring_limits, "reader", "max_bytes"], 1)
        ] do
      assert {:error, :invalid_profile_installation} =
               WotexHome.Host.start_link(data_dir: directory, profile_installation: bad)

      refute File.exists?(directory)
    end

    assert {:error, :invalid_profile_installation} =
             WotexHome.Host.start_link(
               data_dir: directory,
               profile_installation: input,
               profile_installation: input
             )

    refute File.exists?(directory)
  end

  test "path-selected Home compilation cannot assert a pinned producer source" do
    file = Path.expand("lib/wotex_home/profiles/producer_identity.ex")

    script =
      "Code.compile_file(hd(System.argv())); case WotexHome.Profiles.ProducerIdentity.current() do {:error, :profile_runtime_source_unavailable} -> System.halt(0); _ -> System.halt(2) end"

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-e", script, file],
        env: [{"WOTEX_HOME_PATH_DEPS", "1"}, {"WOTEX_HOME_GIT_DEPS", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "new runtime source and read declarations retain exact producer-free history" do
    alias WotexHome.Profiles.{ExternalSourceSelection, ReadDeclarationCodec, RetainedSource}
    {:ok, prepared} = ProfileInstallation.prepare(config("temperature"))
    input = fixture("external-source-selections")["temperature"]["inputs"]

    {:ok, selection} =
      ExternalSourceSelection.new(input["source"], prepared.reader, input["channels"])

    assert {:ok, bytes} = RetainedSource.encode(selection, String.duplicate("a", 32))
    assert {:ok, history} = RetainedSource.decode(bytes)
    assert history.sha256 == selection.sha256

    assert history.inputs["reader"]["installed"]["producer"] ==
             prepared.reader.inputs["installed"]["producer"]

    record = hd(fixture("generic-read-semantics")["temperature"]["thing"]["capabilities"])
    data = JSON.decode!(record["declaration_document"])
    data = Map.put(data, "producer", prepared.reader.inputs["installed"]["producer"])
    {:ok, document} = Wotex.JSON.encode(data)

    digest =
      :crypto.hash(:sha256, "wotex-home.external-read-declaration@1\n" <> document)
      |> Base.encode16(case: :lower)

    record =
      Map.merge(record, %{"declaration_document" => document, "declaration_sha256" => digest})

    assert {:ok, %{"data" => ^data, "record" => ^record}} = ReadDeclarationCodec.decode(record)
  end
end
