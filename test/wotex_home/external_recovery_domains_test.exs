defmodule WotexHome.ExternalRecoveryDomainsTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.Artifact
  alias WotexHome.Recovery.DomainCodec

  defp vectors,
    do: JSON.decode!(File.read!("test/fixtures/profiles/external-recovery-domains.json"))

  test "independent generic recovery records remain inert and preserve exact bytes" do
    for family <- ~w(temperature research multi) do
      vector = vectors()[family]
      assert {:ok, decoded} = DomainCodec.decode(vector["document"])
      assert decoded.version == 3 and decoded.counter_state == "unknown"
      assert decoded.domain_count == 1 and decoded.counter_state_digest == nil
      assert decoded.domain_digest == vector["domain_digest"]
      assert Artifact.digest(vector["document"]) == vector["domain_digest"]

      for method <-
            ~w(physical_disconnection qualified_network_isolation device_credential_revocation unknown) do
        assert {:error, :transfer_domain_isolation_unavailable} =
                 DomainCodec.acceptance_basis(vector["document"], method)
      end
    end
  end

  test "external records cannot drift into legacy versions or resolved transport scope" do
    vector = vectors()["multi"]
    [_, snapshot, counts, [record]] = JSON.decode!(vector["document"])
    caps = Enum.at(record, 5)

    bad_records = [
      record ++ ["extra"],
      List.replace_at(record, 9, ["known"]),
      List.replace_at(record, 2, "external:bad"),
      List.replace_at(record, 3, -1),
      List.replace_at(record, 4, String.duplicate("G", 64)),
      List.replace_at(record, 5, Enum.reverse(caps)),
      List.replace_at(record, 5, [hd(caps), hd(caps)]),
      List.replace_at(record, 5, List.duplicate(hd(caps), 33)),
      List.replace_at(record, 5, [["power", ["read"], "ordinary", "boolean", "none"]]),
      List.replace_at(record, 5, [["external_read", "bad/id", String.duplicate("a", 64)]]),
      List.replace_at(record, 6, ["legacy:binding"]),
      List.replace_at(record, 7, [["legacy:history"]]),
      List.replace_at(record, 8, [["legacy:selection"]])
    ]

    for bad <- bad_records do
      assert {:error, :invalid_transfer_domains} =
               DomainCodec.decode(
                 JSON.encode!(["wotex-home.controller-domains.v3", snapshot, counts, [bad]])
               )
    end

    for version <- ~w(v1 v2) do
      document =
        if version == "v1",
          do: ["wotex-home.controller-domains.v1", snapshot, [record]],
          else: ["wotex-home.controller-domains.v2", snapshot, counts, [record]]

      assert {:error, :invalid_transfer_domains} = DomainCodec.decode(JSON.encode!(document))
    end

    assert {:error, :invalid_transfer_domains} = DomainCodec.decode(vector["document"] <> " ")
  end

  test "mixed inventories retain legacy unresolved records without omitting the generic target" do
    [header, snapshot, counts, records] = JSON.decode!(vectors()["temperature"]["document"])
    legacy = ["missing:legacy", "unresolved", nil, nil, nil, [], nil, [], [], ["unknown"]]
    document = JSON.encode!([header, snapshot, counts, [legacy | records]])
    assert {:ok, decoded} = DomainCodec.decode(document)
    assert decoded.domain_count == 2 and decoded.counter_state == "unknown"

    assert {:error, :transfer_domain_isolation_unavailable} =
             DomainCodec.acceptance_basis(document, "physical_disconnection")
  end
end
