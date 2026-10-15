defmodule WotexHome.ExternalInputHistoryFixture do
  @moduledoc false

  alias WotexHome.Durable.Registry
  alias WotexHome.Durable.Store.{EnrollmentWriter, Journal, PrincipalWriter, SQL}
  alias WotexHome.Profiles.DocumentChunks
  alias WotexHome.Rules.{ExternalInput, ExternalInputOperation, ExternalInputPackage}
  alias WotexHome.Semantics.Thing

  # Structurally retained, unqualified history only. The legacy target has no
  # native reader/source or qualified input; these signatures are never admitted.
  def seed(db, credential, slots \\ ["sample"]) do
    {:ok, thing} =
      Thing.new(%{
        "id" => "sensor:independent",
        "role" => "Light",
        "profile_ref" => "synthetic:archive",
        "capabilities" => [
          %{
            "thing_id" => "sensor:independent",
            "role" => "Light",
            "key" => "power",
            "value_kind" => "boolean",
            "unit" => "none",
            "operations" => ["read", "write"],
            "risk_class" => "ordinary",
            "profile_ref" => "synthetic:archive",
            "evidence_ref" => "fixture:archive",
            "freshness_ms" => 1000,
            "constraints" => %{},
            "extensions" => %{}
          }
        ]
      })

    {:ok, document} = Registry.encode_thing(thing)
    {:ok, {:ok, 1}} = SQL.transaction(db, &EnrollmentWriter.enroll_thing_tx(&1, thing, document))

    {:ok, {:ok, nil, 2}} =
      SQL.transaction(
        db,
        &PrincipalWriter.provision_principal_tx(
          &1,
          "operator:entry",
          :crypto.hash(:sha256, credential),
          "[\"read\",\"host:maintain\"]",
          ["sensor:independent"],
          nil
        )
      )

    for revision <- 3..20 do
      {:ok, {:ok, nil, ^revision}} =
        SQL.transaction(
          db,
          &PrincipalWriter.provision_principal_tx(
            &1,
            "fixture:#{revision}",
            :crypto.hash(:sha256, "fixture:#{revision}"),
            "[\"read\"]",
            [],
            nil
          )
        )
    end

    vector = JSON.decode!(File.read!("test/fixtures/profiles/routine-external-inputs.json"))
    for {key, offset} <- Enum.with_index(slots), do: install(db, vector, key, 21 + offset)
    vector
  end

  defp install(db, v, key, revision) do
    package = package(v, key)
    {:ok, retained} = ExternalInputPackage.decode(package)
    {:ok, definition} = ExternalInput.decode(retained["data"]["definition_document"])

    input =
      Map.merge(v["change"], %{
        "operation_id" => if(key == "sample", do: "install:entry", else: "install:" <> key),
        "capability_key" => key,
        "package_document" => package
      })

    {:ok, input_doc} = ExternalInputOperation.encode(input)

    {:ok, outcome_doc} =
      ExternalInputOperation.encode_outcome(
        Map.merge(v["outcome"], %{
          "capability_key" => key,
          "package_document" => package,
          "definition_sha256" => definition["sha256"]
        })
      )

    receipt =
      Map.merge(v["receipt"], %{
        "operation_id" => input["operation_id"],
        "capability_key" => key,
        "revision" => revision,
        "install_revision" => revision,
        "input_sha256" => ExternalInputOperation.input_sha256(input_doc),
        "outcome_sha256" => ExternalInputOperation.outcome_sha256(outcome_doc)
      })

    {:ok, receipt_doc} = ExternalInputOperation.encode_receipt(receipt)
    {:ok, _} = ExternalInputOperation.validate_original(input_doc, outcome_doc, receipt_doc)
    :ok = Journal.authority_event(db, revision, "external_input_installed", "sensor:independent")

    {:ok, []} =
      SQL.query(
        db,
        "INSERT INTO routine_external_input_operations VALUES ('operator:entry',1,?,?,?,?,?)",
        [input["operation_id"], input_doc, outcome_doc, receipt_doc, revision]
      )

    {:ok, []} =
      SQL.query(
        db,
        "INSERT INTO routine_external_input_history VALUES ('sensor:independent',?,?,1,'install',NULL,?)",
        [key, revision, outcome_doc]
      )

    {:ok, []} =
      SQL.query(
        db,
        "INSERT INTO routine_external_input_current VALUES ('sensor:independent',?,?,?,1,'installed')",
        [key, revision, revision]
      )
  end

  defp package(v, "sample"), do: v["package_document"]

  defp package(v, key) do
    context =
      v["definition"]["context"]
      |> Map.put("capability_key", key)
      |> put_in(["declaration", "capability_key"], key)

    {:ok, bytes} = Wotex.JSON.encode(context)
    {:ok, chunks} = DocumentChunks.encode(bytes, 131_072)

    document =
      v["definition_document"] |> JSON.decode!() |> List.replace_at(1, chunks) |> JSON.encode!()

    {:ok, definition} = ExternalInput.decode(document)

    package =
      v["package"]
      |> Map.put("definition_document", document)
      |> put_in(["signed", "decision", "definition_sha256"], definition["sha256"])

    {:ok, package} = ExternalInputPackage.encode(package)
    package
  end
end
