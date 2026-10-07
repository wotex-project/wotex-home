defmodule WotexHome.RecoveryIssuerPoliciesTest do
  use ExUnit.Case, async: true
  alias WotexHome.Recovery.{IssuerPolicies, PrivateFile}

  setup do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-issuers-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)

    policy = %{
      public_key: public,
      generation: 1,
      method: "physical_disconnection",
      procedure_ref: "procedure:synthetic",
      policy_digest: String.duplicate("a", 64),
      counter_state: "no_radio_state"
    }

    %{root: root, policy: policy, policies: %{"issuer:synthetic" => policy}}
  end

  test "closed records have canonical sorted issuer identity and empty disables trust", c do
    policies = Map.put(c.policies, "issuer:other", %{c.policy | generation: 2})
    assert {:ok, document} = IssuerPolicies.encode(policies)
    assert {:ok, ^policies} = IssuerPolicies.decode(document)
    assert {:ok, [_, records]} = JSON.decode(document)

    assert Enum.map(records, fn [_, values] -> hd(values) end) == [
             "issuer:other",
             "issuer:synthetic"
           ]

    assert {:ok, empty} = IssuerPolicies.encode(%{})
    assert {:ok, %{}} = IssuerPolicies.decode(empty)
  end

  test "duplicates, reordered records and noncanonical or unknown documents refuse", c do
    {:ok, document} = IssuerPolicies.encode(Map.put(c.policies, "issuer:other", c.policy))
    {:ok, [format, records]} = JSON.decode(document)

    for bytes <- [
          document <> "\n",
          JSON.encode!([format, Enum.reverse(records)]),
          JSON.encode!([format, [hd(records), hd(records)]]),
          JSON.encode!([format, records, true]),
          JSON.encode!(["wotex-home.controller-isolation-issuers.v2", records]),
          JSON.encode!([format, %{}]),
          "{}",
          String.duplicate(" ", 65_537),
          nil
        ] do
      assert {:error, :invalid_isolation_issuer_configuration} = IssuerPolicies.decode(bytes)
    end
  end

  test "finite current policy set refuses invalid records and excess issuers", c do
    policies = Map.new(1..32, fn n -> {"issuer:#{n}", c.policy} end)
    assert {:ok, document} = IssuerPolicies.encode(policies)
    assert {:ok, ^policies} = IssuerPolicies.decode(document)
    assert {:error, _} = IssuerPolicies.encode(Map.put(policies, "issuer:extra", c.policy))

    for policy <- [%{c.policy | generation: 1.0}, Map.put(c.policy, :trusted, true), nil] do
      assert {:error, _} = IssuerPolicies.encode(%{"issuer:synthetic" => policy})
    end
  end

  test "explicit private installation repeats original custody and withdraws replaced bytes", c do
    path = Path.join(c.root, "current-issuers.json")
    {:ok, document} = IssuerPolicies.encode(c.policies)
    :ok = PrivateFile.write(path, document, 65_536)
    assert {:ok, provider} = IssuerPolicies.open(path)
    assert provider.() == c.policies
    File.rename!(path, path <> ".original")
    :ok = PrivateFile.write(path, document, 65_536)
    assert provider.() == %{}
    assert {:ok, newly_selected} = IssuerPolicies.open(path)
    assert newly_selected.() == c.policies
    File.rm!(path)
    assert newly_selected.() == %{}
  end

  test "missing, mutable, malformed and linked policy custody cannot be installed", c do
    path = Path.join(c.root, "current-issuers.json")
    assert {:error, _} = IssuerPolicies.open(path)
    {:ok, document} = IssuerPolicies.encode(c.policies)
    :ok = PrivateFile.write(path, document, 65_536)
    File.chmod!(path, 0o600)
    assert {:error, _} = IssuerPolicies.open(path)
    File.chmod!(path, 0o400)
    File.ln!(path, path <> ".alias")
    assert {:error, _} = IssuerPolicies.open(path)
    File.rm!(path <> ".alias")
    File.chmod!(path, 0o600)
    File.write!(path, "{}")
    File.chmod!(path, 0o400)
    assert {:error, :invalid_isolation_issuer_configuration} = IssuerPolicies.open(path)
  end
end
