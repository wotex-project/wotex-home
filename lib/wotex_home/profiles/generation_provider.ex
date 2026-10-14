defmodule WotexHome.Profiles.GenerationProvider do
  @moduledoc """
  Checks a trusted local adapter process against its declared generator identity.

  `new/2` binds the existing provider/model/build/locality record to an explicit
  alive local PID. `installation/1` checks the finite ordered set before Store
  ownership; `select/2` rechecks the selected process before use. Registered or
  remote names, callback code and credentials are not part of this value.

  The identity describes trusted host composition. It does not authenticate an
  external model, grant source export permission or establish OS confinement.
  Store must repeat current actor/policy/source and durable attempt guards.
  """

  alias WotexHome.Id
  alias WotexHome.Profiles.{AuthoringProducer, EnvelopeCodec}
  @enforce_keys [:provider, :provider_sha256, :pid]
  @derive {Inspect, only: [:provider_sha256]}
  defstruct @enforce_keys

  @doc "Constructs a checked exact provider identity for one alive local PID."
  def new(provider, pid) do
    with {:ok, digest} <- identity(provider),
         true <- is_pid(pid) and node(pid) == node() and Process.alive?(pid),
         do: {:ok, %__MODULE__{provider: provider, provider_sha256: digest, pid: pid}},
         else: (_ -> invalid())
  end

  @doc "Computes the shared domain-separated provider identity without process state."
  def identity(p) do
    if EnvelopeCodec.keys?(p, ~w(adapter_sha256 id locality model_id)) and
         Id.valid?(p["id"]) and Id.valid?(p["model_id"]) and
         EnvelopeCodec.digest?(p["adapter_sha256"]) and p["locality"] in ~w(local remote),
       do:
         {:ok,
          AuthoringProducer.sha(
            "wotex-home.generation-provider@1\n" <>
              JSON.encode!(Enum.map(~w(id model_id adapter_sha256 locality), &p[&1]))
          )},
       else: invalid()
  end

  def validate(%__MODULE__{} = p) when map_size(p) == 4 do
    with {:ok, ^p} <- new(p.provider, p.pid), do: :ok, else: (_ -> invalid())
  end

  def validate(_), do: invalid()

  @doc "Checks at most 32 sorted unique identities and distinct process owners."
  def installation(providers) do
    with :ok <- bounded(providers, 32),
         true <- Enum.all?(providers, &(validate(&1) == :ok)),
         ids = Enum.map(providers, & &1.provider_sha256),
         pids = Enum.map(providers, & &1.pid),
         true <- ids == Enum.sort(Enum.uniq(ids)) and pids == Enum.uniq(pids),
         do: :ok,
         else: (_ -> invalid())
  end

  @doc "Rechecks the exact installed process; absence/death never selects a fallback."
  def select(providers, digest) do
    with :ok <- bounded(providers, 32),
         true <- EnvelopeCodec.digest?(digest),
         %__MODULE__{} = p <-
           Enum.find(providers, &match?(%__MODULE__{provider_sha256: ^digest}, &1)),
         :ok <- validate(p),
         do: {:ok, p},
         else: (_ -> {:error, :generation_unavailable})
  end

  defp bounded([], _), do: :ok
  defp bounded([_ | _], 0), do: invalid()
  defp bounded([_ | tail], n), do: bounded(tail, n - 1)
  defp bounded(_, _), do: invalid()
  defp invalid, do: {:error, :invalid_generation_provider}
end
