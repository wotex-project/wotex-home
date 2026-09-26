defmodule WotexHome.DiscoveryTest do
  use ExUnit.Case, async: true

  alias WotexHome.Discovery.{Candidate, Interview, Inventory, Profile}

  @candidate %{
    "interface_id" => "en0",
    "transport" => "udp",
    "source_endpoint" => "192.0.2.10:56700",
    "receive_epoch" => "scan:1",
    "received_monotonic_ms" => 100,
    "raw_ref" => "capture:1",
    "claimed_identifiers" => %{
      "manufacturer" => "LIFX",
      "model" => "old-eu",
      "stable_id" => "d073d5000001"
    },
    "trust_class" => "untrusted_network"
  }

  @interview %{
    "candidate_ref" => "capture:1",
    "transport" => "udp",
    "manufacturer" => "LIFX",
    "model" => "old-eu",
    "firmware" => "2.0",
    "stable_id" => "d073d5000001"
  }

  @profile %{
    "id" => "lifx.old-eu",
    "version" => "1.0.0",
    "transport" => "udp",
    "manufacturer" => "LIFX",
    "model" => "old-eu",
    "firmware_versions" => ["2.0"],
    "rank" => 10,
    "qualification_ref" => "cohort:old-eu:1"
  }

  test "discovery retains spoofable claims without promoting them" do
    assert {:ok, %Candidate{} = candidate} = Candidate.new(@candidate)
    assert candidate.claimed_identifiers["stable_id"] == "d073d5000001"
    assert {:error, :invalid_fields} = Candidate.new(Map.put(@candidate, "enrolled", true))

    assert {:error, :invalid_metadata} =
             Candidate.new(%{@candidate | "source_endpoint" => String.duplicate("a", 257)})

    assert {:error, :invalid_claims} =
             Candidate.new(%{@candidate | "claimed_identifiers" => %{"credential" => "secret"}})
  end

  test "duplicate claimed identities remain visible" do
    assert {:ok, first} = Candidate.new(@candidate)

    assert {:ok, second} =
             Candidate.new(%{
               @candidate
               | "raw_ref" => "capture:2",
                 "source_endpoint" => "192.0.2.11:56700"
             })

    conflicts = Inventory.conflicts([first, second])
    assert length(conflicts[{"stable_id", "d073d5000001"}]) == 2
  end

  test "interview must be linked to its candidate but does not authenticate it" do
    assert {:ok, candidate} = Candidate.new(@candidate)
    assert {:ok, %Interview{} = interview} = Interview.new(@interview, candidate)
    assert interview.stable_id == "d073d5000001"

    assert {:error, :invalid_identity} =
             Interview.new(%{@interview | "candidate_ref" => "capture:other"}, candidate)

    assert {:error, :invalid_fields} =
             Interview.new(Map.put(@interview, "operator_approved", true), candidate)
  end

  test "only an exact firmware match yields a profile hint" do
    assert {:ok, candidate} = Candidate.new(@candidate)
    assert {:ok, interview} = Interview.new(@interview, candidate)
    assert {:ok, profile} = Profile.new(@profile)
    assert {:ok, ^profile} = Profile.match(interview, [profile])
    assert {:error, :unsupported} = Profile.match(%{interview | firmware: "2.1"}, [profile])
  end

  test "equal ranked matching profiles are ambiguous" do
    assert {:ok, candidate} = Candidate.new(@candidate)
    assert {:ok, interview} = Interview.new(@interview, candidate)
    assert {:ok, first} = Profile.new(@profile)
    assert {:ok, second} = Profile.new(%{@profile | "id" => "lifx.other"})
    assert {:error, :ambiguous_profile} = Profile.match(interview, [first, second])
  end

  test "a higher rank is only a match hint, not enrollment" do
    assert {:ok, candidate} = Candidate.new(@candidate)
    assert {:ok, interview} = Interview.new(@interview, candidate)
    assert {:ok, lower} = Profile.new(@profile)
    assert {:ok, higher} = Profile.new(%{@profile | "id" => "lifx.exact", "rank" => 20})
    assert {:ok, ^higher} = Profile.match(interview, [lower, higher])
    refute Map.has_key?(higher, :credential_ref)
  end
end
