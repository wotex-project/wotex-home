defmodule WotexHome.ExternalInputDecisionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Qualification.{Attestation, ExternalInputDecision}
  alias WotexHome.Rules.ExternalInput

  setup_all do
    v = JSON.decode!(File.read!("test/fixtures/profiles/routine-external-inputs.json"))
    d = v["definition"]
    {:ok, native} = ExternalInput.new(d["context"], d["mapping"], d["registry"])

    %{
      v: v,
      p: v["package"],
      native: native,
      case_keys: %{"case-entry" => Base.url_decode64!(v["case_public_key"], padding: false)},
      decision_keys: %{
        "decision-entry" => Base.url_decode64!(v["decision_public_key"], padding: false)
      }
    }
  end

  test "programme and decision payload equal the independently frozen bytes", c do
    assert {:ok, cases, digest} = ExternalInputDecision.programme()
    programme = JSON.decode!(File.read!("priv/qualification/external-routine-input-v1.json"))
    assert cases == programme["cases"]
    assert digest == c.v["programme_sha256"]
    assert Enum.count(cases, &(&1["environment"] == "hardware")) == 4
    assert Enum.all?(cases, &(&1["capability_key"] == "external_input"))
    assert {:ok, payload} = ExternalInputDecision.signing_payload(c.p["signed"]["decision"])
    assert Base.encode64(payload) == c.v["decision_signing_payload_base64"]

    for d <- [
          nil,
          %{},
          Map.put(c.p["signed"]["decision"], "qualified", true),
          Map.put(c.p["signed"]["decision"], "outcome", "allow_direct_power"),
          Map.put(c.p["signed"]["decision"], "definition_sha256", String.duplicate("A", 64))
        ] do
      assert {:error, :invalid_external_input_decision} = ExternalInputDecision.signing_payload(d)
    end
  end

  test "the complete synthetic signed claim verifies without creating current Store authority",
       c do
    expected = c.p["signed"]["decision"]
    assert {:ok, ^expected} = verify(c, c.p)
    assert {:ok, ^expected} = verify(c, Map.update!(c.p, "attestations", &Enum.reverse/1))
    assert map_size(expected) == 7
    assert c.v["scope"] == "synthetic_software_entry_only"
    refute Map.has_key?(expected, "qualified")

    for keys <- [%{}, Map.put(c.case_keys, "case-entry", String.duplicate(<<0>>, 32))] do
      result =
        ExternalInputDecision.verify(
          c.p["signed"],
          c.native,
          c.p["cohort"],
          c.p["attestations"],
          keys,
          c.decision_keys
        )

      assert {:error, code} = result
      assert code in [:qualification_unavailable, :invalid_external_input_decision]
    end

    assert {:error, :qualification_unavailable} =
             ExternalInputDecision.verify(
               c.p["signed"],
               c.native,
               c.p["cohort"],
               c.p["attestations"],
               c.case_keys,
               %{}
             )
  end

  test "every signed identity, signature, cohort and native field is rechecked", c do
    for p <-
          [
            put_in(c.p, ["signed", "signature"], c.p["signed"]["signature"] <> "="),
            put_in(c.p, ["signed", "signature"], String.duplicate("A", 86)),
            put_in(c.p, ["signed", "extra"], true),
            put_in(c.p, ["cohort", "firmware"], "changed"),
            put_in(c.p, ["attestations", Access.at!(0), "signature"], String.duplicate("A", 86))
          ] ++
            for(
              field <- ~w(definition_sha256 programme_sha256 cohort_sha256 evidence_set_sha256),
              do: put_in(c.p, ["signed", "decision", field], String.duplicate("0", 64))
            ) do
      assert {:error, :invalid_external_input_decision} = verify(c, p)
    end

    for native <- [
          Map.from_struct(c.native),
          Map.put(c.native, :extra, true),
          %{c.native | sha256: String.duplicate("0", 64)},
          %{c.native | document: c.native.document <> " "}
        ] do
      assert {:error, :invalid_external_input_decision} = verify(%{c | native: native}, c.p)
    end

    for keys <- [
          %{"case-entry" => <<0>>},
          Map.put(c.case_keys, "bad id", String.duplicate(<<0>>, 32)),
          Map.new(1..33, &{"case:#{&1}", String.duplicate(<<0>>, 32)})
        ] do
      assert {:error, :invalid_external_input_decision} =
               ExternalInputDecision.verify(
                 c.p["signed"],
                 c.native,
                 c.p["cohort"],
                 c.p["attestations"],
                 keys,
                 c.decision_keys
               )
    end
  end

  test "validly re-signed failed, missing, extra, duplicate and wrong-environment cases still refuse",
       c do
    change_first = fn attestations, transform -> List.update_at(attestations, 0, transform) end

    transforms = [
      &tl/1,
      fn a -> a ++ [hd(a)] end,
      fn a -> List.replace_at(a, 1, hd(a)) end,
      fn a -> change_first.(a, &put_in(&1, ["receipt", "environment"], "fixture")) end,
      fn a ->
        change_first.(a, fn entry ->
          entry
          |> put_in(["receipt", "status"], "failed")
          |> put_in(["receipt", "assertions", Access.at!(0), "actual"], false)
        end)
      end,
      fn a -> change_first.(a, &put_in(&1, ["receipt", "cohort", "firmware"], "other")) end,
      fn a -> change_first.(a, &put_in(&1, ["receipt", "case_id"], "ERI-other")) end,
      fn a -> change_first.(a, &put_in(&1, ["receipt", "requirement_id"], "H20-99")) end
    ]

    for transform <- transforms do
      {p, case_keys, decision_keys} = resign(c, transform.(c.p["attestations"]))

      for a <- p["attestations"] do
        assert {:ok, _} = Attestation.verify(a, c.v["programme_sha256"], case_keys)
      end

      assert {:error, :invalid_external_input_decision} =
               verify(%{c | case_keys: case_keys, decision_keys: decision_keys}, p)
    end
  end

  test "separate reviewer IDs and actual key bytes are mandatory even when every signature is valid",
       c do
    for options <- [[], [same_key: true], [decision_id: "case-entry"]] do
      {p, case_keys, decision_keys} = resign(c, c.p["attestations"], options)

      for a <- p["attestations"] do
        assert {:ok, _} = Attestation.verify(a, c.v["programme_sha256"], case_keys)
      end

      signed = p["signed"]

      payload =
        "WOH11-external-input-decision-v1\0" <>
          :erlang.term_to_binary(signed["decision"], [:deterministic])

      assert :crypto.verify(
               :eddsa,
               :none,
               payload,
               Base.url_decode64!(signed["signature"], padding: false),
               [decision_keys[signed["decision"]["reviewer_key_id"]], :ed25519]
             )

      result = verify(%{c | case_keys: case_keys, decision_keys: decision_keys}, p)

      if options == [],
        do: assert(match?({:ok, _}, result)),
        else: assert(result == {:error, :invalid_external_input_decision})
    end
  end

  test "missing, changed and oversized programme bytes refuse within a private application directory" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "woh-input-programme-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    script = """
    alias WotexHome.Qualification.ExternalInputDecision
    for module <- [ExternalInputDecision, WotexHome.Qualification.Evidence, WotexHome.Profiles.EnvelopeCodec], do: Code.ensure_loaded!(module)
    directory = #{inspect(directory)}
    try do
      original = ExternalInputDecision |> :code.which() |> List.to_string() |> Path.dirname()
      programme = File.read!(Application.app_dir(:wotex_home, "priv/qualification/external-routine-input-v1.json"))
      private_home = Path.join(directory, "wotex_home")
      private = Path.join(private_home, "ebin")
      File.mkdir_p!(private)
      File.cp!(Path.join(original, "wotex_home.app"), Path.join(private, "wotex_home.app"))
      true = :code.del_path(String.to_charlist(original))
      true = :code.add_patha(String.to_charlist(private))
      true = Application.app_dir(:wotex_home) == private_home
      {:error, :qualification_unavailable} = ExternalInputDecision.programme()
      path = Path.join(private_home, "priv/qualification/external-routine-input-v1.json")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, programme)
      {:ok, cases, digest} = ExternalInputDecision.programme()
      true = length(cases) == 8
      true = byte_size(digest) == 64
      for bytes <- [programme <> " ", String.duplicate("x", 16_385), ""] do
        File.write!(path, bytes)
        {:error, :qualification_unavailable} = ExternalInputDecision.programme()
      end
      IO.puts("verified pinned programme refusals")
    after
      File.rm_rf!(directory)
    end
    """

    try do
      arguments =
        Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end) ++
          ["-e", script]

      assert {"verified pinned programme refusals\n", 0} =
               System.cmd(System.find_executable("elixir"), arguments, stderr_to_stdout: true)
    after
      File.rm_rf!(directory)
    end

    refute File.exists?(directory)
  end

  defp verify(c, p),
    do:
      ExternalInputDecision.verify(
        p["signed"],
        c.native,
        p["cohort"],
        p["attestations"],
        c.case_keys,
        c.decision_keys
      )

  defp resign(c, attestations, options \\ []) do
    {case_public, case_private} = :crypto.generate_key(:eddsa, :ed25519)

    {decision_public, decision_private} =
      if options[:same_key],
        do: {case_public, case_private},
        else: :crypto.generate_key(:eddsa, :ed25519)

    decision_id = Keyword.get(options, :decision_id, "decision-entry")

    attestations =
      Enum.map(attestations, fn a ->
        {:ok, payload} =
          Attestation.signing_payload(a["reviewer_key_id"], c.v["programme_sha256"], a["receipt"])

        Map.put(a, "signature", sign(payload, case_private))
      end)

    decision =
      c.p["signed"]["decision"]
      |> Map.put("reviewer_key_id", decision_id)
      |> Map.put(
        "evidence_set_sha256",
        hash(Enum.sort_by(attestations, & &1["receipt"]["case_id"]))
      )

    payload =
      "WOH11-external-input-decision-v1\0" <> :erlang.term_to_binary(decision, [:deterministic])

    p = %{
      c.p
      | "attestations" => attestations,
        "signed" => %{"decision" => decision, "signature" => sign(payload, decision_private)}
    }

    {p, %{"case-entry" => case_public}, %{decision_id => decision_public}}
  end

  defp sign(payload, private),
    do:
      :crypto.sign(:eddsa, :none, payload, [private, :ed25519])
      |> Base.url_encode64(padding: false)

  defp hash(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
