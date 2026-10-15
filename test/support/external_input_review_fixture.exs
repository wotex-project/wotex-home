Code.require_file("routine_external_fact_fixture.exs", __DIR__)

defmodule WotexHome.ExternalInputReviewFixture do
  @moduledoc false

  alias WotexHome.Authority
  alias WotexHome.Profiles.EnvelopeCodec
  alias WotexHome.Qualification.{Attestation, Evidence, ExternalInputDecision}
  alias WotexHome.Rules.{ExternalInput, ExternalInputFormat, ExternalInputPackage}
  alias WotexHome.RoutineExternalFactFixture, as: R

  def keys do
    {case_public, case_private} = :crypto.generate_key(:eddsa, :ed25519)
    {decision_public, decision_private} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      case_keys: %{"case-entry" => case_public},
      case_private: case_private,
      decision_keys: %{"decision-entry" => decision_public},
      decision_private: decision_private
    }
  end

  # These are synthetic signed claims for software trust-mechanics tests. Neither
  # the generated assertions nor their hardware-labelled case fields are bench
  # evidence; no test private key or resulting package is written to disk.
  def review(c, nonce \\ "first", key \\ "sample", options \\ []) do
    v = R.read("routine-external-inputs")
    prototype = Keyword.get(options, :mapping, v["definition"]["mapping"])

    {:ok, context} =
      Authority.external_routine_input_context(c.authority, c.credential, "sensor:external", key)

    basis =
      prototype["basis"]
      |> put_in(["implementation_digest"], "sha256:" <> context["runtime_sha256"])
      |> put_in(["compiler_digest"], "sha256:" <> context["runtime_sha256"])
      |> Map.put("output", nil)
      |> put_in(["affordance", "name"], context["reader"]["affordance"]["name"])
      |> put_in(["evidence", "freshness_ms"], Keyword.get(options, :freshness_ms, 1000))
      |> put_in(
        ["evidence", "require_source_time"],
        Keyword.get(options, :require_source_time, true)
      )

    body = Map.drop(basis, ~w(byte_digest semantic_digest implementation_digest compiler_digest))
    basis = Map.put(basis, "byte_digest", "sha256:" <> digest(R.encode(body)))

    unsigned =
      prototype
      |> Map.delete("sha256")
      |> Map.merge(
        Map.take(
          context["reader"],
          ~w(profile_sha256 closure_sha256 capture_digest compiler_ref reader_contract_ref channel_id affordance semantic_ref external_unit)
        )
      )
      |> Map.merge(%{
        "basis" => basis,
        "receipt_clock" => context["receipt_clock"]
      })
      |> put_in(["observation", "source_ref"], context["source_ref"])
      |> put_in(["observation", "source_epoch"], context["source_epoch"])
      |> put_in(
        ["observation", "source_time_basis"],
        Keyword.get(
          options,
          :source_time_basis,
          prototype["observation"]["source_time_basis"]
        )
      )

    mapping =
      R.install(
        %{
          mapping: unsigned,
          context: %{
            "registry" => Keyword.get(options, :registry, v["definition"]["registry"]),
            "limits" => ExternalInputFormat.limits()
          }
        },
        unsigned
      )

    {:ok, definition} = ExternalInput.new(context, mapping.mapping, mapping.context["registry"])

    cohort =
      v["package"]["cohort"]
      |> Map.put("source_identity_ref", context["stable_id_sha256"])
      |> Map.put("runtime", context["runtime_sha256"])
      |> Map.put("application", "synthetic:store-trust-only")

    attestations =
      Enum.map(v["package"]["attestations"], fn attestation ->
        receipt =
          attestation["receipt"]
          |> Map.put("cohort", cohort)
          |> Map.put("source_identity_ref", cohort["source_identity_ref"])
          |> Map.update!("receipt_id", &(&1 <> ":" <> nonce))
          |> Map.put("artifact_digests", [
            digest("synthetic claim\n" <> nonce <> attestation["receipt"]["case_id"])
          ])

        {:ok, payload} = Attestation.signing_payload("case-entry", v["programme_sha256"], receipt)
        %{attestation | "receipt" => receipt, "signature" => sign(payload, c.case_private)}
      end)

    {:ok, cohort_sha} = Evidence.cohort_digest(cohort)

    decision =
      v["package"]["signed"]["decision"]
      |> Map.put("definition_sha256", definition.sha256)
      |> Map.put("cohort_sha256", cohort_sha)
      |> Map.put(
        "evidence_set_sha256",
        digest(:erlang.term_to_binary(attestations, [:deterministic]))
      )

    {:ok, payload} = ExternalInputDecision.signing_payload(decision)

    {:ok, package} =
      ExternalInputPackage.encode(%{
        v["package"]
        | "definition_document" => definition.document,
          "cohort" => cohort,
          "attestations" => attestations,
          "signed" => %{"decision" => decision, "signature" => sign(payload, c.decision_private)}
      })

    true = EnvelopeCodec.digest?(definition.sha256)
    %{context: context, definition: definition, package: package}
  end

  def install(review, operation \\ "install:live", previous \\ nil) do
    %{
      "authority_epoch" => review.context["authority_epoch"],
      "operation_id" => operation,
      "target_id" => review.context["target_id"],
      "capability_key" => review.context["capability_key"],
      "expected_install_revision" => if(previous, do: previous["install_revision"], else: 0),
      "expected_generation" => if(previous, do: previous["generation"], else: 0),
      "action" => "install",
      "package_document" => review.package
    }
  end

  def revoke(receipt, operation \\ "revoke:live") do
    receipt
    |> Map.take(~w(authority_epoch target_id capability_key))
    |> Map.merge(%{
      "operation_id" => operation,
      "expected_install_revision" => receipt["install_revision"],
      "expected_generation" => receipt["generation"],
      "action" => "revoke",
      "package_document" => nil
    })
  end

  defp sign(payload, private),
    do:
      :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
      |> Base.url_encode64(padding: false)

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
