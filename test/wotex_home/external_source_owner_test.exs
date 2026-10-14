defmodule WotexHome.ExternalSourceOwnerTest do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Profiles.{ExternalSourceOwner, ExternalSourceSelection, ReaderSelection}

  test "invalid or duplicate configuration never starts custody" do
    for options <- [
          nil,
          %{},
          [:bad],
          [],
          [publisher: self(), ttl_ms: 99],
          [publisher: self(), lease_limit: 33],
          [publisher: self(), source_limit: 0],
          [publisher: self(), max_bytes: 4_194_305],
          [publisher: self(), unknown: true],
          [publisher: self(), name: 123],
          [publisher: self(), ttl_ms: 100, ttl_ms: 200]
        ] do
      assert {:error, :invalid_external_source_owner} = ExternalSourceOwner.start_link(options)
    end
  end

  test "cold metadata lookup is closed and publication requires the actual producer and publisher" do
    owner = start_supervised!({ExternalSourceOwner, publisher: self()})

    assert {:ok, %{"owner_epoch" => epoch, "sources" => []}} =
             ExternalSourceOwner.catalogue(owner)

    ref = %{
      "authority_epoch" => 1,
      "operation_id" => "source:1",
      "input_sha256" => String.duplicate("a", 64)
    }

    assert :not_found = ExternalSourceOwner.hold(owner, "operator:1", ref, "source:1", epoch)
    assert :not_found = ExternalSourceOwner.status(owner, "operator:1", 1, "source:1")

    assert {:error, :invalid_external_source_lease} =
             ExternalSourceOwner.hold(
               owner,
               "operator:1",
               Map.put(ref, "extra", true),
               "source:1",
               epoch
             )

    assert {:error, :invalid_external_source_lease} =
             ExternalSourceOwner.status(owner, "operator:1", 0, "source:1")

    assert {:error, :invalid_external_source_lease} =
             ExternalSourceOwner.checkout(owner, "operator:1", "bad", ref)

    assert {:error, :external_source_publisher_denied} =
             Task.async(fn -> ExternalSourceOwner.publish(owner, %{}) end) |> Task.await()

    source =
      JSON.decode!(File.read!("test/fixtures/profiles/external-source-selections.json"))[
        "temperature"
      ]

    reader =
      JSON.decode!(File.read!("test/fixtures/profiles/external-inspections.json"))["temperature"]

    value = %ExternalSourceSelection{
      inputs: %{
        "source" => source["inputs"]["source"],
        "channels" => source["inputs"]["channels"],
        "reader" => %ReaderSelection{
          inputs: reader["reader_inputs"],
          data: reader["reader_summary"]
        }
      },
      data: source["data"],
      sha256: source["sha256"]
    }

    assert {:ok, _} = ExternalSourceOwner.publish(owner, value)
    assert {:ok, %{"sources" => [_]}} = ExternalSourceOwner.catalogue(owner)
  end
end
