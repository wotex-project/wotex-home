defmodule WotexHome.Rules.ExternalInputRuntime do
  @moduledoc """
  Captures the compiled runtime used to review an external routine input.

  `current/0` returns `{:ok, runtime, sha256}` after freshly inventorying four
  bounded groups: the ten-application routine cohort, native core/Runtime/Profiles
  producer, transport dependencies and storage dependencies. The closed runtime
  record has format `wotex-home.external-input-runtime@1`, `"profiles"` and
  `"routines_sha256"`, `"transport_sha256"`, `"storage_sha256"` fields.
  The combined digest is an unprefixed lowercase SHA-256 string.

  The profiles group starts with `WotexHome.Profiles.ProducerIdentity.current/0`,
  then independently compares fresh inventories for each of its three applications
  against that native assertion. Group inventories use the internal fresh-read
  path in `WotexHome.RuntimeArtifacts`, bypassing an enclosing Store inventory
  memo. A Store guard's opening bytes cannot substitute for these
  fresh reads or a later closing check. Artifact reads and temporary readers
  retain RuntimeArtifacts' existing bounds and cleanup.

  `digest/1` returns `{:ok, sha256}` after validating and hashing supplied runtime
  data, without measuring installed code. It requires the closed native profile
  assertion shape; legacy three-archive assertions refuse. A well-formed native
  claim may still be historical, so its reproducible digest establishes no
  current correspondence.

  `check_current/2` checks the supplied shape/digest, captures all four groups
  freshly, and requires exact equality of both runtime data and digest. It
  returns `:ok` on a match. Invalid claims, missing artifacts, unavailable native
  producer assertions and inventory drift return the same payload-free
  `{:error, :runtime_artifact_unavailable}` across all three APIs.

  This identity binds complete BEAM artifacts, module inventories and application
  versions. It supplies no Store authorization, source custody, current Fact or
  physical qualification. ERTS, OS/native libraries and actual transport/device
  behavior require their separate evidence; a matching code digest grants no
  permission to collect or execute.
  """

  alias WotexHome.Profiles.{EnvelopeCodec, ProducerIdentity}
  alias WotexHome.RuntimeArtifacts

  @format "wotex-home.external-input-runtime@1"
  @profile_format "wotex-home.profile-producer-runtime@1"
  @fields ~w(format profiles routines_sha256 storage_sha256 transport_sha256)
  @digests ~w(routines_sha256 transport_sha256 storage_sha256)
  @transport [:wotex_binding_mqtt, :emqtt, :gun, :cowlib, :wotex_udp]
  @storage [:exqlite, :db_connection, :telemetry]
  @profiles [
    {"core_runtime_sha256", :wotex},
    {"runtime_runtime_sha256", :wotex_runtime},
    {"profiles_runtime_sha256", :wotex_profiles}
  ]

  @doc "Returns freshly measured runtime data and its domain-separated SHA-256."
  @spec current() :: {:ok, map(), String.t()} | {:error, :runtime_artifact_unavailable}
  def current do
    guarded(fn ->
      with {:ok, routines} <-
             RuntimeArtifacts.fresh_digest(
               RuntimeArtifacts.temporal_applications(),
               domain("routines")
             ),
           {:ok, profiles} <- current_profiles(),
           {:ok, transport} <- RuntimeArtifacts.fresh_digest(@transport, domain("transport")),
           {:ok, storage} <- RuntimeArtifacts.fresh_digest(@storage, domain("storage")),
           data = %{
             "format" => @format,
             "routines_sha256" => routines,
             "profiles" => profiles,
             "transport_sha256" => transport,
             "storage_sha256" => storage
           },
           {:ok, sha256} <- digest(data) do
        {:ok, data, sha256}
      end
    end)
  end

  @doc "Checks a claimed runtime's exact shape and digest without measuring installed code."
  @spec digest(term()) :: {:ok, String.t()} | {:error, :runtime_artifact_unavailable}
  def digest(data) do
    if EnvelopeCodec.keys?(data, @fields) and data["format"] == @format and
         native_profiles?(data["profiles"]) and
         Enum.all?(@digests, &EnvelopeCodec.digest?(data[&1])) do
      values = [
        data["routines_sha256"],
        ProducerIdentity.values(data["profiles"]),
        data["transport_sha256"],
        data["storage_sha256"]
      ]

      {:ok,
       :crypto.hash(:sha256, @format <> "\n" <> JSON.encode!(values))
       |> Base.encode16(case: :lower)}
    else
      unavailable()
    end
  end

  @doc "Requires freshly measured data and digest to equal the complete claimed runtime."
  @spec check_current(term(), term()) :: :ok | {:error, :runtime_artifact_unavailable}
  def check_current(data, sha256) do
    with {:ok, ^sha256} <- digest(data),
         {:ok, ^data, ^sha256} <- current() do
      :ok
    else
      _ -> unavailable()
    end
  end

  defp current_profiles do
    with {:ok, profiles} <- ProducerIdentity.current(),
         true <- native_profiles?(profiles),
         true <-
           Enum.all?(@profiles, fn {field, app} ->
             RuntimeArtifacts.fresh_digest([app], @profile_format) == {:ok, profiles[field]}
           end) do
      {:ok, profiles}
    else
      _ -> unavailable()
    end
  end

  defp native_profiles?(profiles),
    do:
      ProducerIdentity.valid?(profiles) and
        profiles["format"] == @profile_format

  defp domain(group), do: "wotex-home.external-input-runtime:" <> group <> "@1"

  defp guarded(callback) do
    case callback.() do
      {:ok, data, sha256} -> {:ok, data, sha256}
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp unavailable, do: {:error, :runtime_artifact_unavailable}
end
