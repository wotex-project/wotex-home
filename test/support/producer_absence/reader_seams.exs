defmodule HomeAbsentReaderSeams do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Profiles.ReaderSelection

  test "reader producer remains unavailable without its code path" do
    v =
      JSON.decode!(File.read!("test/fixtures/profiles/external-inspections.json"))["temperature"][
        "reader_inputs"
      ]

    assert {:error, :profiles_producer_unavailable} =
             ReaderSelection.new(v["installed"], v["capture"], v["reader_limits"])
  end

  test "runtime producer history validates without loading a current producer" do
    identity = %{
      "format" => "wotex-home.profile-producer-runtime@1",
      "source_revision" => "ba8ea373244ce57987f47a731b8eca3ccae9b45f",
      "core_runtime_sha256" => String.duplicate("0", 64),
      "runtime_runtime_sha256" => String.duplicate("1", 64),
      "profiles_runtime_sha256" => String.duplicate("2", 64)
    }

    assert WotexHome.Profiles.ProducerIdentity.valid?(identity)

    assert {:ok, ^identity} =
             WotexHome.Profiles.ProducerIdentity.from_wire([
               identity["format"],
               identity["source_revision"],
               identity["core_runtime_sha256"],
               identity["runtime_runtime_sha256"],
               identity["profiles_runtime_sha256"]
             ])

    refute Code.ensure_loaded?(Wotex.Profiles.Contract)

    assert {:error, :runtime_artifact_unavailable} =
             WotexHome.Profiles.ProducerIdentity.check_current(identity)
  end
end
