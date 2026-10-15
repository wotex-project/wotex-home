defmodule WotexHome.Profiles.ProducerIdentity do
  @moduledoc """
  Retains historical producer assertions and checks the installed runtime cohort.

  `valid?/1` checks the closed assertion shape. Runtime assertions accept any
  canonical 40-character lowercase hexadecimal source revision, so retained
  history remains readable after a dependency pin changes. `from_wire/1` applies
  the same historical validation, returning `{:ok, identity}` or
  `{:error, :invalid_profile_producer}`. Neither function establishes that a
  historical source revision or its asserted digests match the installed code.

  `current/0` returns `{:ok, identity}` with the pinned core, Runtime and Profiles
  source revision and their actual compiled-code inventory digests. A build
  compiled with neighboring path dependencies returns
  `{:error, :profile_runtime_source_unavailable}` instead of a current production
  identity. Inventory failures propagate as error tuples.

  For a runtime assertion, `check_current/1` requires exact equality with
  `current/0`, returning `:ok`, `{:error, :stale_profile_runtime}` for a different
  cohort, or the current-inventory error. Malformed assertions return
  `{:error, :invalid_profile_producer}`. Legacy three-digest archive assertions
  retain their compatibility behavior: `check_current/1` returns `:ok` for their
  valid shape without claiming a current compiled runtime inventory.

  `values/1` converts a validated identity to its ordered three-item archive or
  five-item tagged runtime wire form; `from_wire/1` preserves either closed
  representation. These checks do not qualify native dependencies, devices or
  the profile's household meaning.
  """

  alias WotexHome.Profiles.EnvelopeCodec
  alias WotexHome.RuntimeArtifacts

  @format "wotex-home.profile-producer-runtime@1"
  @revision "687a5cd70267fa47dbfb36e28eccad6ef2964fdf"
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
         data["format"] == @format and revision?(data["source_revision"]) and
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

  defp revision?(value),
    do: is_binary(value) and byte_size(value) == 40 and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)

  defp archive?(data),
    do:
      EnvelopeCodec.keys?(data, Enum.sort(@archives)) and
        Enum.all?(@archives, &EnvelopeCodec.digest?(data[&1]))

  defp checked(data),
    do: if(valid?(data), do: {:ok, data}, else: {:error, :invalid_profile_producer})
end
