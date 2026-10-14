defmodule WotexHome.ExternalValueUnavailableTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.{ExternalEnvelope, ExternalReadDeclaration, ExternalValue}

  test "absent optional producer cannot be replaced by a native value or local conversion" do
    v = JSON.decode!(File.read!("test/fixtures/profiles/temperature.json"))

    record = fn data, ref ->
      bytes = JSON.encode!(data)

      %{
        "reference" => ref,
        "bytes" => bytes,
        "raw_sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      }
    end

    installed =
      Map.take(v, ~w(bindings contracts home_contracts))
      |> Map.put("producer", %{
        "core_archive_sha256" => String.duplicate("a", 64),
        "runtime_archive_sha256" => String.duplicate("b", 64),
        "profiles_archive_sha256" => String.duplicate("c", 64)
      })

    envelope = %ExternalEnvelope{
      bytes: JSON.encode!(v["envelope"]),
      data: v["envelope"],
      raw_sha256: String.duplicate("0", 64),
      projection: nil,
      projection_sha256: String.duplicate("0", 64),
      consumption_sha256: String.duplicate("0", 64),
      documents: %{
        "profile" => record.(v["profile"], v["envelope"]["profile"]),
        "definitions" => Enum.zip_with(v["definitions"], v["envelope"]["definitions"], record)
      },
      inputs: %{
        "installed" => installed,
        "capture" => v["capture"],
        "reader_limits" => v["reader_limits"]
      }
    }

    contract =
      JSON.decode!(File.read!("test/fixtures/profiles/external-values.json"))["temperature"][
        "contract"
      ]

    report =
      JSON.decode!(File.read!("test/fixtures/profiles/authoring-fixtures.json"))["temperature"][
        "fixtures"
      ]
      |> hd()
      |> Map.fetch!("report")

    assert {:error, :profiles_producer_unavailable} =
             ExternalValue.project(envelope, report, contract, v["reader_limits"])

    assert {:error, :invalid_external_value} =
             ExternalValue.to_map(%{}, envelope, contract, v["reader_limits"])

    policy =
      JSON.decode!(File.read!("test/fixtures/profiles/external-read-declarations.json"))[
        "temperature"
      ]["policy"]

    assert {:error, :profiles_producer_unavailable} =
             ExternalReadDeclaration.new(envelope, contract, policy, "sample", v["reader_limits"])

    assert {:error, :invalid_external_declaration} =
             ExternalReadDeclaration.to_map(%{}, envelope, contract, policy, v["reader_limits"])

    assert {:error, :external_profile_limit} = ExternalValue.consumer_identity(contract, nil)

    assert {:error, :external_profile_limit} =
             ExternalValue.consumer_identity(
               contract,
               Map.put(v["reader_limits"], "max_nodes", 4097)
             )
  end
end
