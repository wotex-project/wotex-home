defmodule WotexHome.Profiles.GenerationPolicy do
  @moduledoc """
  Binds one installed generator to an actor and explicit source export ceilings.

  `new/1` checks provider/model/build identity, locality, remote consent and the
  exact permitted passage ranges, fixture handles and projection limits.
  `installation/1` checks a bounded, ordered policy set. `select/3` matches an
  authenticated principal and original request against that installed set.

  Policies describe trusted native configuration; they contain no endpoint,
  provider credential, source bytes or executable callback. Reconstruction and
  identity checks establish correspondence, not provider authentication or
  confinement. Store must still check owned references and current authority
  before any preparation, and a later handoff must repeat those checks.
  """

  alias WotexHome.Id

  alias WotexHome.Profiles.{
    AuthoringProducer,
    EnvelopeCodec,
    GenerationInput,
    GenerationPreparation
  }

  @enforce_keys [:input, :sha256, :provider_sha256]
  @derive {Inspect, only: [:sha256, :provider_sha256]}
  defstruct @enforce_keys

  def new(input) do
    with true <-
           EnvelopeCodec.keys?(
             input,
             ~w(examples limits passages principal_id provider remote_export)
           ),
         true <- Id.valid?(input["principal_id"]),
         p = input["provider"],
         true <- EnvelopeCodec.keys?(p, ~w(adapter_sha256 id locality model_id)),
         true <-
           Id.valid?(p["id"]) and Id.valid?(p["model_id"]) and
             EnvelopeCodec.digest?(p["adapter_sha256"]) and p["locality"] in ~w(local remote),
         true <-
           is_boolean(input["remote_export"]) and
             (p["locality"] != "local" or input["remote_export"] == false),
         request =
           Map.take(input, ~w(passages examples limits))
           |> Map.merge(%{"contract_digest" => String.duplicate("0", 64), "instruction" => ""}),
         :ok <- GenerationInput.validate_request(request) do
      [_, _, passages, examples, limits] = GenerationPreparation.projection_values(request)
      provider = Enum.map(~w(id model_id adapter_sha256 locality), &p[&1])

      bytes =
        JSON.encode!([
          input["principal_id"],
          provider,
          input["remote_export"],
          passages,
          examples,
          limits
        ])

      {:ok,
       %__MODULE__{
         input: input,
         sha256: AuthoringProducer.sha("wotex-home.generation-policy@1\n" <> bytes),
         provider_sha256:
           AuthoringProducer.sha("wotex-home.generation-provider@1\n" <> JSON.encode!(provider))
       }}
    else
      _ -> {:error, :invalid_generation_policy}
    end
  end

  def validate(%__MODULE__{} = p) when map_size(p) == 4 do
    with {:ok, ^p} <- new(p.input), do: :ok, else: (_ -> {:error, :invalid_generation_policy})
  end

  def validate(_), do: {:error, :invalid_generation_policy}

  def installation(policies) do
    with :ok <- bounded(policies, 32),
         true <- Enum.all?(policies, &(validate(&1) == :ok)),
         keys = Enum.map(policies, &{&1.input["principal_id"], &1.input["provider"]["id"]}),
         true <- keys == Enum.sort(Enum.uniq(keys)),
         do: :ok,
         else: (_ -> {:error, :invalid_generation_policy})
  end

  def select(policies, principal, request) do
    with :ok <- installation(policies),
         policy when not is_nil(policy) <-
           Enum.find(
             policies,
             &(&1.input["principal_id"] == principal and
                 &1.provider_sha256 == request["provider_sha256"])
           ),
         true <- policy.sha256 == request["policy_sha256"] do
      p = policy.input
      r = request["projection"]

      allowed =
        r["limits"] == p["limits"] and Enum.all?(r["passages"], &(&1 in p["passages"])) and
          Enum.all?(r["examples"], &(&1 in p["examples"])) and
          if(p["provider"]["locality"] == "remote",
            do: p["remote_export"] and request["remote_export"],
            else: request["remote_export"] == false
          )

      if allowed, do: {:ok, policy}, else: {:error, :generation_export_denied}
    else
      nil -> {:error, :generation_unavailable}
      false -> {:error, :stale_generation_policy}
      error -> error
    end
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: :error
  defp bounded([_ | rest], n), do: bounded(rest, n - 1)
  defp bounded(_, _), do: :error
end
