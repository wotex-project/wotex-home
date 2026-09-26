defmodule WotexHome.Discovery.EnrollmentReview do
  @moduledoc """
  Pure screening of an explicit enrollment selection.

  A review binds one candidate, read-only interview, exact packaged profile
  hint and proposed Thing. The operator ID in the selection is an attribution
  claim until a future authority service authenticates it. A successful
  review does not enroll or grant device command authority.
  """

  alias WotexHome.Discovery.{Candidate, Interview, Inventory, Profile}
  alias WotexHome.Durable.Registry
  alias WotexHome.Id
  alias WotexHome.Semantics.Thing

  @selection_keys ~w(operator_id candidate_ref stable_id profile_ref qualification_ref method review_ref)

  @enforce_keys [
    :operator_id,
    :candidate_ref,
    :stable_id,
    :profile_ref,
    :qualification_ref,
    :thing_id,
    :method,
    :review_ref,
    :identity_digest,
    :status
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new([Candidate.t()], Interview.t(), [Profile.t()], Thing.t(), map()) ::
          {:ok, t()} | {:error, atom()}
  def new(candidates, %Interview{} = interview, profiles, %Thing{} = thing, selection)
      when is_list(candidates) and length(candidates) > 0 and length(candidates) <= 128 and
             is_list(profiles) and length(profiles) > 0 and length(profiles) <= 64 and
             is_map(selection) do
    with :ok <- valid_selection(selection),
         {:ok, candidate} <- selected_candidate(candidates, selection["candidate_ref"]),
         :ok <- valid_inputs(candidates, candidate, interview, profiles, thing),
         :ok <- no_claim_collision(candidates, candidate),
         :ok <- consistent_claims(candidate, interview),
         {:ok, profile} <- Profile.match(interview, profiles),
         :ok <- binding(selection, candidate, interview, profile, thing),
         {:ok, document} <- Registry.encode_thing(thing) do
      profile_ref = profile_ref(profile)

      digest =
        {selection["operator_id"], candidate.raw_ref, interview.stable_id, profile_ref,
         profile.qualification_ref, thing.id, document, selection["method"]}
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok,
       %__MODULE__{
         operator_id: selection["operator_id"],
         candidate_ref: candidate.raw_ref,
         stable_id: interview.stable_id,
         profile_ref: profile_ref,
         qualification_ref: profile.qualification_ref,
         thing_id: thing.id,
         method: selection["method"],
         review_ref: selection["review_ref"],
         identity_digest: digest,
         status: :pending_authenticated_commit
       }}
    end
  end

  def new(_candidates, _interview, _profiles, _thing, _selection),
    do: {:error, :invalid_enrollment_review}

  defp valid_selection(selection) do
    if Enum.sort(Map.keys(selection)) == Enum.sort(@selection_keys) and
         Enum.all?(
           ~w(operator_id candidate_ref stable_id profile_ref qualification_ref review_ref),
           &Id.valid?(selection[&1])
         ) and
         selection["method"] in ~w(legacy_tofu operator_configured physical_button qr_install_code),
       do: :ok,
       else: {:error, :invalid_selection}
  end

  defp selected_candidate(candidates, candidate_ref) do
    case Enum.filter(candidates, &match?(%Candidate{raw_ref: ^candidate_ref}, &1)) do
      [candidate] -> {:ok, candidate}
      _ -> {:error, :ambiguous_or_missing_candidate}
    end
  end

  defp valid_inputs(candidates, candidate, interview, profiles, thing) do
    with true <- Enum.all?(candidates, &valid_candidate?/1),
         {:ok, ^candidate} <- Candidate.new(string_keys(candidate)),
         {:ok, ^interview} <- Interview.new(string_keys(interview), candidate),
         true <- Enum.all?(profiles, &valid_profile?/1),
         {:ok, _document} <- Registry.encode_thing(thing) do
      :ok
    else
      _ -> {:error, :invalid_enrollment_evidence}
    end
  end

  defp valid_candidate?(%Candidate{} = candidate),
    do: Candidate.new(string_keys(candidate)) == {:ok, candidate}

  defp valid_candidate?(_candidate), do: false

  defp valid_profile?(%Profile{} = profile),
    do: Profile.new(string_keys(profile)) == {:ok, profile}

  defp valid_profile?(_profile), do: false

  defp no_claim_collision(candidates, candidate) do
    conflicts = Inventory.conflicts(candidates)

    if Enum.any?(conflicts, fn {{key, _value}, members} ->
         key == "stable_id" and candidate in members
       end),
       do: {:error, :claimed_identity_collision},
       else: :ok
  end

  defp consistent_claims(candidate, interview) do
    claims = candidate.claimed_identifiers

    if Enum.all?(~w(manufacturer model firmware stable_id), fn key ->
         not Map.has_key?(claims, key) or
           Map.fetch!(claims, key) == Map.fetch!(string_keys(interview), key)
       end),
       do: :ok,
       else: {:error, :identity_claim_mismatch}
  end

  defp binding(selection, candidate, interview, profile, thing) do
    expected_profile_ref = profile_ref(profile)

    if selection["candidate_ref"] == candidate.raw_ref and
         selection["stable_id"] == interview.stable_id and
         selection["profile_ref"] == expected_profile_ref and
         selection["qualification_ref"] == profile.qualification_ref and
         thing.profile_ref == expected_profile_ref and thing.id != interview.stable_id and
         method_for_transport?(selection["method"], candidate.transport) do
      :ok
    else
      {:error, :selection_mismatch}
    end
  end

  defp method_for_transport?(method, transport) when transport in ["udp", "mdns"],
    do: method == "legacy_tofu"

  defp method_for_transport?(method, "configured"), do: method == "operator_configured"

  defp method_for_transport?(method, "zigbee"),
    do: method in ["physical_button", "qr_install_code"]

  defp profile_ref(profile), do: profile.id <> ":" <> profile.version

  defp string_keys(struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
