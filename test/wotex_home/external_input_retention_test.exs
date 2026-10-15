defmodule WotexHome.ExternalInputRetentionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Profiles.DocumentChunks
  alias WotexHome.Rules.{ExternalInputOperation, ExternalInputPackage}

  setup_all do
    v = JSON.decode!(File.read!("test/fixtures/profiles/routine-external-inputs.json"))

    %{
      v: v,
      p: v["package"],
      context: v["definition"]["context"],
      case_keys: %{"case-entry" => Base.url_decode64!(v["case_public_key"], padding: false)},
      decision_keys: %{
        "decision-entry" => Base.url_decode64!(v["decision_public_key"], padding: false)
      }
    }
  end

  test "package bytes, identity and live verification match the independent frozen original", c do
    assert {:ok, c.v["package_document"]} == ExternalInputPackage.encode(c.p)
    assert {:ok, historical} = ExternalInputPackage.decode(c.v["package_document"])

    assert historical == %{
             "data" => c.p,
             "document" => c.v["package_document"],
             "sha256" => c.v["package_sha256"]
           }

    assert {:ok, ^historical} = verify(c, c.v["package_document"])

    assert {:error, :qualification_unavailable} =
             ExternalInputPackage.verify(c.v["package_document"], c.context, %{}, %{})

    assert {:error, :external_input_basis_changed} =
             ExternalInputPackage.verify(
               c.v["package_document"],
               Map.put(c.context, "selection_revision", 12),
               %{},
               %{}
             )
  end

  test "historical signature syntax remains separate from live key trust", c do
    p = put_in(c.p, ["signed", "signature"], String.duplicate("A", 86))
    assert {:ok, bytes} = ExternalInputPackage.encode(p)
    assert {:ok, _} = ExternalInputPackage.decode(bytes)
    assert {:error, :invalid_external_input_decision} = verify(c, bytes)

    for p <- [
          put_in(c.p, ["signed", "signature"], c.p["signed"]["signature"] <> "="),
          put_in(
            c.p,
            ["signed", "signature"],
            binary_part(c.p["signed"]["signature"], 0, 85) <> "B"
          ),
          put_in(c.p, ["attestations", Access.at!(0), "signature"], String.duplicate("B", 86))
        ] do
      assert {:error, _} = ExternalInputPackage.encode(p)
    end
  end

  test "closed historical package scope requires exact passed cases and cohort identities", c do
    for p <- [
          Map.put(c.p, "qualified", true),
          Map.update!(c.p, "attestations", &Enum.reverse/1),
          Map.update!(c.p, "attestations", &tl/1),
          Map.update!(c.p, "attestations", &(&1 ++ [hd(&1)])),
          Map.update!(c.p, "attestations", &List.replace_at(&1, 1, hd(&1))),
          put_in(c.p, ["cohort", "firmware"], "other"),
          put_in(c.p, ["signed", "decision", "definition_sha256"], String.duplicate("0", 64)),
          put_in(c.p, ["signed", "decision", "programme_sha256"], String.duplicate("0", 64)),
          put_in(c.p, ["signed", "decision", "cohort_sha256"], String.duplicate("0", 64)),
          put_in(c.p, ["signed", "decision", "evidence_set_sha256"], String.duplicate("0", 64)),
          put_in(c.p, ["signed", "decision", "reviewer_key_id"], "case-entry"),
          put_in(c.p, ["attestations", Access.at!(0), "receipt", "authorized"], true)
        ] do
      assert {:error, _} = ExternalInputPackage.encode(p)
    end

    p =
      c.p
      |> put_in(["attestations", Access.at!(0), "receipt", "status"], "failed")
      |> put_in(
        ["attestations", Access.at!(0), "receipt", "assertions", Access.at!(0), "actual"],
        false
      )

    p = evidence_hash(p)
    assert {:error, _} = ExternalInputPackage.encode(p)
  end

  test "historical package parsing checks exact outer encoding, chunks and duplicate-free inner JSON",
       c do
    wire = JSON.decode!(c.v["package_document"])
    {:ok, signed} = DocumentChunks.decode(Enum.at(wire, 2), 65_536)

    duplicate =
      String.replace_prefix(
        signed,
        "{",
        "{\"signature\":\"" <> c.p["signed"]["signature"] <> "\","
      )

    {:ok, chunks} = DocumentChunks.encode(duplicate, 65_536)

    for bytes <- [
          c.v["package_document"] <> " ",
          JSON.encode!(List.replace_at(wire, 2, chunks)),
          JSON.encode!(wire ++ ["extra"]),
          JSON.encode!(
            List.replace_at(wire, 2, [
              binary_part(signed, 0, 10),
              binary_part(signed, 10, byte_size(signed) - 10)
            ])
          )
        ] do
      assert {:error, _} = ExternalInputPackage.decode(bytes)
    end

    {:ok, spaced} = DocumentChunks.encode(" " <> signed, 65_536)
    historical_bytes = JSON.encode!(List.replace_at(wire, 2, spaced))
    assert {:ok, historical} = ExternalInputPackage.decode(historical_bytes)
    assert historical["data"] == c.p
    refute historical["sha256"] == c.v["package_sha256"]
    assert {:error, :invalid_external_input} = verify(c, historical_bytes)
  end

  test "inner attestation bytes and complete package wire have independent actual byte ceilings",
       c do
    commands = Enum.map(1..64, &String.pad_trailing("command:#{&1}", 128, "x"))

    p =
      Map.update!(c.p, "attestations", fn attestations ->
        Enum.map(attestations, &put_in(&1, ["receipt", "command_sequence"], commands))
      end)
      |> evidence_hash()

    assert {:error, :external_input_limit} = ExternalInputPackage.encode(p)

    assert {:error, :external_input_limit} =
             ExternalInputPackage.decode(String.duplicate(" ", 262_145))

    wire = JSON.decode!(c.v["package_document"])
    {:ok, oversized} = DocumentChunks.encode(String.duplicate(" ", 65_537), 65_537)

    assert {:error, :external_input_limit} =
             ExternalInputPackage.decode(JSON.encode!(List.replace_at(wire, 2, oversized)))
  end

  test "all change, outcome and receipt documents match their independent ordered originals", c do
    assert {:ok, c.v["change_document"]} == ExternalInputOperation.encode(c.v["change"])
    assert {:ok, c.v["outcome_document"]} == ExternalInputOperation.encode_outcome(c.v["outcome"])
    assert {:ok, c.v["receipt_document"]} == ExternalInputOperation.encode_receipt(c.v["receipt"])
    assert {:ok, c.v["change"]} == ExternalInputOperation.decode(c.v["change_document"])
    assert {:ok, c.v["outcome"]} == ExternalInputOperation.decode_outcome(c.v["outcome_document"])
    assert {:ok, c.v["receipt"]} == ExternalInputOperation.decode_receipt(c.v["receipt_document"])
    assert {:ok, original} = original(c.v["change"], c.v["outcome"], c.v["receipt"])

    assert original == %{
             "input" => c.v["change"],
             "outcome" => c.v["outcome"],
             "receipt" => c.v["receipt"]
           }
  end

  test "changes require exact slot/epoch/package correspondence and coherent missing-slot counters",
       c do
    for i <- [
          Map.put(c.v["change"], "extra", true),
          Map.put(c.v["change"], "target_id", "other"),
          Map.put(c.v["change"], "capability_key", "other"),
          Map.put(c.v["change"], "authority_epoch", 2),
          Map.put(c.v["change"], "expected_install_revision", 1),
          Map.put(c.v["change"], "expected_generation", 1),
          Map.put(c.v["change"], "package_document", nil),
          Map.put(c.v["change"], "action", "revoke"),
          c.v["change"] |> Map.put("action", "revoke") |> Map.put("package_document", nil),
          Map.put(c.v["change"], "action", "withdraw")
        ] do
      assert {:error, _} = ExternalInputOperation.encode(i)
    end

    for o <- [
          Map.put(c.v["outcome"], "target_id", "other"),
          Map.put(c.v["outcome"], "capability_key", "other"),
          Map.put(c.v["outcome"], "definition_sha256", String.duplicate("0", 64))
        ] do
      assert {:error, _} = ExternalInputOperation.encode_outcome(o)
    end
  end

  test "receipt grammar distinguishes install, revoke and withdrawal without manufacturing a first revoke",
       c do
    for receipt <- [
          Map.put(c.v["receipt"], "extra", true),
          Map.put(c.v["receipt"], "install_revision", 20),
          Map.put(c.v["receipt"], "generation", 0),
          Map.put(c.v["receipt"], "action", "revoke"),
          c.v["receipt"] |> Map.put("action", "revoke") |> Map.put("install_revision", 20),
          Map.put(c.v["receipt"], "action", "withdraw")
        ] do
      assert {:error, _} = ExternalInputOperation.encode_receipt(receipt)
    end

    outcome = Map.put(c.v["outcome"], "action", "withdraw")
    assert {:ok, bytes} = ExternalInputOperation.encode_outcome(outcome)
    assert {:ok, ^outcome} = ExternalInputOperation.decode_outcome(bytes)
  end

  test "original joins reject coherent individual documents with changed scope, hashes, counters or install boot",
       c do
    for r <- [
          Map.put(c.v["receipt"], "authority_epoch", 2),
          Map.put(c.v["receipt"], "operation_id", "other"),
          Map.put(c.v["receipt"], "target_id", "other"),
          Map.put(c.v["receipt"], "capability_key", "other"),
          Map.put(c.v["receipt"], "input_sha256", String.duplicate("0", 64)),
          Map.put(c.v["receipt"], "outcome_sha256", String.duplicate("0", 64)),
          Map.put(c.v["receipt"], "generation", 2),
          Map.put(c.v["receipt"], "store_boot_epoch", "store:other"),
          c.v["receipt"] |> Map.put("revision", 10) |> Map.put("install_revision", 10)
        ] do
      assert {:ok, rdoc} = ExternalInputOperation.encode_receipt(r)

      assert {:error, _} =
               ExternalInputOperation.validate_original(
                 c.v["change_document"],
                 c.v["outcome_document"],
                 rdoc
               )
    end

    changed_input =
      c.v["change"]
      |> Map.put("expected_install_revision", 22)
      |> Map.put("expected_generation", 1)

    r = Map.put(c.v["receipt"], "generation", 2)
    assert {:error, _} = original(changed_input, c.v["outcome"], r)
  end

  test "explicit revoke preserves the old installation after a new Store boot and authority epoch",
       c do
    i =
      c.v["change"]
      |> Map.merge(%{
        "authority_epoch" => 2,
        "operation_id" => "revoke:later",
        "action" => "revoke",
        "package_document" => nil,
        "expected_install_revision" => 21,
        "expected_generation" => 1
      })

    o = Map.put(c.v["outcome"], "action", "revoke")

    r =
      c.v["receipt"]
      |> Map.merge(%{
        "authority_epoch" => 2,
        "operation_id" => "revoke:later",
        "action" => "revoke",
        "revision" => 30,
        "generation" => 2,
        "store_boot_epoch" => "store:later"
      })

    assert {:ok, value} = original(i, o, r)
    assert value["receipt"]["install_revision"] == 21
    assert value["outcome"]["package_document"] == c.v["package_document"]

    assert {:error, _} = original(i, o, Map.put(r, "install_revision", 20))
  end

  test "explicit reinstallation advances generation without changing or refunding an old original",
       c do
    i =
      c.v["change"]
      |> Map.merge(%{
        "operation_id" => "install:again",
        "expected_install_revision" => 21,
        "expected_generation" => 2
      })

    r =
      c.v["receipt"]
      |> Map.merge(%{
        "operation_id" => "install:again",
        "revision" => 40,
        "install_revision" => 40,
        "generation" => 3
      })

    assert {:ok, value} = original(i, c.v["outcome"], r)
    assert value["receipt"]["install_revision"] == 40

    assert {:ok, _} =
             ExternalInputOperation.validate_original(
               c.v["change_document"],
               c.v["outcome_document"],
               c.v["receipt_document"]
             )
  end

  test "canonical wire and byte ceilings apply to every retained operation layer", c do
    for {bytes, decoder, ceiling} <- [
          {c.v["change_document"], &ExternalInputOperation.decode/1, 524_288},
          {c.v["outcome_document"], &ExternalInputOperation.decode_outcome/1, 524_288},
          {c.v["receipt_document"], &ExternalInputOperation.decode_receipt/1, 4096}
        ] do
      assert {:error, _} = decoder.(bytes <> " ")
      assert {:error, _} = decoder.(JSON.encode!(JSON.decode!(bytes) ++ ["extra"]))
      assert {:error, :external_input_limit} = decoder.(String.duplicate(" ", ceiling + 1))
    end
  end

  test "all retained history works with actual producers and the current programme file unavailable" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "woh-input-history-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    script = """
    alias WotexHome.Qualification.ExternalInputDecision
    alias WotexHome.Rules.{ExternalInputOperation, ExternalInputPackage}
    v = JSON.decode!(File.read!("test/fixtures/profiles/routine-external-inputs.json"))
    {:ok, expected} = ExternalInputPackage.decode(v["package_document"])
    {:ok, expected_original} = ExternalInputOperation.validate_original(v["change_document"],v["outcome_document"],v["receipt_document"])
    directory = #{inspect(directory)}
    try do
      original = ExternalInputDecision |> :code.which() |> List.to_string() |> Path.dirname()
      private_home = Path.join(directory, "wotex_home")
      private = Path.join(private_home, "ebin")
      File.mkdir_p!(private)
      File.cp!(Path.join(original, "wotex_home.app"), Path.join(private, "wotex_home.app"))
      true = :code.del_path(String.to_charlist(original))
      true = :code.add_patha(String.to_charlist(private))
      true = Application.app_dir(:wotex_home) == private_home
      for module <- [Wotex.JSON,Wotex.Runtime.Context,Wotex.Profiles.Proposal,Wotex.Routines.InputMapping] do
        path = module |> :code.which() |> List.to_string() |> Path.dirname() |> String.to_charlist()
        true = :code.del_path(path)
      end
      false = Code.ensure_loaded?(Wotex.JSON)
      false = Code.ensure_loaded?(Wotex.Profiles.Proposal)
      false = Code.ensure_loaded?(Wotex.Routines.InputMapping)
      {:error, :qualification_unavailable} = ExternalInputDecision.programme()
      {:ok, ^expected} = ExternalInputPackage.decode(v["package_document"])
      {:ok, ^expected_original} = ExternalInputOperation.validate_original(v["change_document"],v["outcome_document"],v["receipt_document"])
      {:ok, _} = ExternalInputOperation.encode_outcome(v["outcome"])
      {:error, :external_input_unavailable} = ExternalInputPackage.encode(v["package"])
      {:error, :external_input_unavailable} = ExternalInputPackage.verify(v["package_document"],v["definition"]["context"],%{},%{})
      IO.puts("verified historical package/original without producers or current programme")
    after
      File.rm_rf!(directory)
    end
    """

    try do
      arguments =
        Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end) ++
          ["-e", script]

      assert {"verified historical package/original without producers or current programme\n", 0} =
               System.cmd(System.find_executable("elixir"), arguments, stderr_to_stdout: true)
    after
      File.rm_rf!(directory)
    end

    refute File.exists?(directory)
  end

  defp verify(c, document),
    do: ExternalInputPackage.verify(document, c.context, c.case_keys, c.decision_keys)

  defp original(input, outcome, receipt) do
    with {:ok, idoc} <- ExternalInputOperation.encode(input),
         {:ok, odoc} <- ExternalInputOperation.encode_outcome(outcome),
         r =
           receipt
           |> Map.put("input_sha256", ExternalInputOperation.input_sha256(idoc))
           |> Map.put("outcome_sha256", ExternalInputOperation.outcome_sha256(odoc)),
         {:ok, rdoc} <- ExternalInputOperation.encode_receipt(r),
         do: ExternalInputOperation.validate_original(idoc, odoc, rdoc)
  end

  defp evidence_hash(p) do
    bytes = :erlang.term_to_binary(p["attestations"], [:deterministic])

    put_in(
      p,
      ["signed", "decision", "evidence_set_sha256"],
      Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    )
  end
end
