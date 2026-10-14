defmodule WotexHome.Profiles.ProducerIdentity do
  @moduledoc """
  Represents historical producer assertions and checks installed runtime identity.

  `current/0` inventories the pinned core, Runtime and Profiles applications and
  returns their exact compiled-code digests and source revision. Neighboring path
  dependencies cannot establish that production identity. `check_current/1`
  rechecks runtime identities against the currently installed artifacts.

  Legacy three-digest archive assertions remain decodable for retained history;
  they are not a new runtime inventory. Wire conversion preserves either closed
  representation. Identity checks do not qualify native dependencies, devices
  or the profile's household meaning.
  """

  alias WotexHome.Profiles.EnvelopeCodec
  alias WotexHome.RuntimeArtifacts

  @format "wotex-home.profile-producer-runtime@1"
  @revision "ba8ea373244ce57987f47a731b8eca3ccae9b45f"
  @archives ~w(core_archive_sha256 runtime_archive_sha256 profiles_archive_sha256)
  @runtime ~w(core_runtime_sha256 runtime_runtime_sha256 profiles_runtime_sha256)
  @applications [:wotex, :wotex_runtime, :wotex_profiles]
  @pinned_sources not (System.get_env("WOTEX_HOME_PATH_DEPS") == "1" and
                         System.get_env("WOTEX_HOME_GIT_DEPS") != "1")

  def current do
    if @pinned_sources, do: current_runtime(), else: {:error, :profile_runtime_source_unavailable}
  end

  defp current_runtime do
    Enum.zip(@runtime, @applications)
    |> Enum.reduce_while({:ok, %{"format" => @format, "source_revision" => @revision}}, fn
      {key, app}, {:ok, data} ->
        case RuntimeArtifacts.digest([app], @format) do
          {:ok, digest} -> {:cont, {:ok, Map.put(data, key, digest)}}
          error -> {:halt, error}
        end
    end)
  end

  def valid?(data) do
    archive?(data) or
      (EnvelopeCodec.keys?(data, Enum.sort(~w(format source_revision) ++ @runtime)) and
         data["format"] == @format and data["source_revision"] == @revision and
         Enum.all?(@runtime, &EnvelopeCodec.digest?(data[&1])))
  end

  def check_current(data) do
    cond do
      archive?(data) ->
        :ok

      not valid?(data) ->
        {:error, :invalid_profile_producer}

      true ->
        case current() do
          {:ok, ^data} -> :ok
          {:ok, _} -> {:error, :stale_profile_runtime}
          error -> error
        end
    end
  end

  def values(data) do
    if archive?(data),
      do: Enum.map(@archives, &data[&1]),
      else: Enum.map(~w(format source_revision) ++ @runtime, &data[&1])
  end

  def from_wire([core, runtime, profiles]),
    do: checked(Map.new(Enum.zip(@archives, [core, runtime, profiles])))

  def from_wire([format, revision, core, runtime, profiles]),
    do:
      checked(
        Map.new(
          Enum.zip(~w(format source_revision) ++ @runtime, [
            format,
            revision,
            core,
            runtime,
            profiles
          ])
        )
      )

  def from_wire(_), do: {:error, :invalid_profile_producer}

  defp archive?(data),
    do:
      EnvelopeCodec.keys?(data, Enum.sort(@archives)) and
        Enum.all?(@archives, &EnvelopeCodec.digest?(data[&1]))

  defp checked(data),
    do: if(valid?(data), do: {:ok, data}, else: {:error, :invalid_profile_producer})
end
