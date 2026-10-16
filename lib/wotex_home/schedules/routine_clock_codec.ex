defmodule WotexHome.Schedules.RoutineClockCodec do
  @moduledoc """
  Encodes inert elapsed approvals and independent elapsed/UTC basis identities.

  All inputs are complete plain string-keyed claims; unknown members and native
  structs refuse. `WotexHome.Schedules.RoutineClockCodec.policy_document/1`
  returns `{:ok, bytes}` for the thirteen-field elapsed policy, and
  `WotexHome.Schedules.RoutineClockCodec.decode_policy/1` returns `{:ok, policy}`
  only for its exact canonical ordered-array bytes. Policy members are
  source_id, reference_id, procedure_ref, qualification_digest, runtime_digest,
  source_digest, approval_timeout_ms, maximum_sample_ms,
  maximum_discontinuity_ms, drift_ppm, qualified_run_ms, monotonic_policy and
  suspend_policy. Durations are milliseconds; drift is parts per million.
  Approval timeout is 1–60,000 ms; maximum sample width is 1–1,000 ms;
  discontinuity allowance and drift are 0–1,000 in their respective units.
  Qualified run duration is exactly 86,400,000 ms. The policy strings are
  `"invalidate_on_discontinuity"` and `"invalidate_on_lifecycle_change"`.

  `WotexHome.Schedules.RoutineClockCodec.binding/1` returns `{:ok, binding}`
  for exactly deployment_id, owner_id, authority_epoch, store_boot_epoch,
  elapsed_generation, runtime_digest and monotonic_origin_ms.
  `WotexHome.Schedules.RoutineClockCodec.request_document/1` adds policy_sha256,
  source_digest, reference_epoch, reference_started_ms, lifecycle_generation,
  lifecycle_started_ms and challenge_nonce to that binding, returning
  `{:ok, bytes}`. `WotexHome.Schedules.RoutineClockCodec.decode_request/1`
  reconstructs the fourteen-field request only from exact canonical bytes.
  Raw origin/reference/lifecycle starts in these claims are canonical signed
  decimal strings, preserving negative VM coordinates; no leading zeros or
  negative zero are accepted. The challenge is canonical unpadded base64url of
  exactly 32 bytes.

  Usage sketch with a complete supplied policy:

      {:ok, bytes} = WotexHome.Schedules.RoutineClockCodec.policy_document(policy)
      {:ok, ^policy} = WotexHome.Schedules.RoutineClockCodec.decode_policy(bytes)

  `WotexHome.Schedules.RoutineClockCodec.observation/2` takes an observation and
  policy and returns `{:ok, observation}` after checking source identity,
  ordered raw endpoints and maximum sample width. Its ten fields are source_id,
  reference_id, source_digest, reference_epoch, reference_started_ms,
  lifecycle_generation, lifecycle_started_ms, primary_lower_ms,
  primary_upper_ms and continuous_ms. Native starts/endpoints are signed-64
  integer milliseconds; continuous_ms is nonnegative. This validates a supplied
  observation without reading a native source.

  `WotexHome.Schedules.RoutineClockCodec.utc_scope/1` validates exactly
  deployment_id, owner_id, authority_epoch, store_boot_epoch, clock_generation
  and runtime_digest. `WotexHome.Schedules.RoutineClockCodec.utc_sample/2`
  validates an original `WotexHome.Schedules.ClockSample` map against that scope,
  requiring qualified UTC, monotonic continuity and matching boot/generation.
  Both return `{:ok, map}`.

  `WotexHome.Schedules.RoutineClockCodec.elapsed_token/1` hashes the full original
  request into `{:ok, "home:elapsed:" <> digest}`.
  `WotexHome.Schedules.RoutineClockCodec.utc_token/4` takes UTC scope, original
  sample, Store-relative exchange start and native observation, returning
  `{:ok, "home:utc:" <> digest}`. It binds the original scope/sample/start and
  reference/lifecycle witness. Digests are lowercase SHA-256; fresh sample time
  does not renew an existing token.

  Canonical documents fit 4,096 bytes, depth three, sixteen array members and
  128-byte strings. Identity digests use bare lowercase hex64; reference epochs
  use hex32. Malformed or out-of-policy claims return
  `{:error, :invalid_routine_clock}`; exceeded wire/string or signed-integer
  limits return `{:error, :routine_clock_limit}`; incompatible supplied
  source/qualification claims return `{:error, :routine_clock_unavailable}`.
  Errors contain no supplied payload and no partial value is returned.

  These pure operations measure no clock, Store, file or runtime inventory.
  The actual clock owner and `WotexHome.Durable.Store` establish custody,
  current source/lifecycle identity and one-time approval. Tokens authenticate
  no input and grant no admission, continuing clock trust or effect authority.
  """

  alias WotexHome.Id
  alias WotexHome.Schedules.ClockSample

  @maximum 9_223_372_036_854_775_807
  @minimum -9_223_372_036_854_775_808
  @policy "wotex-home.routine-elapsed-policy.v1"
  @request "wotex-home.routine-elapsed-request.v1"
  @policy_fields ~w(source_id reference_id procedure_ref qualification_digest runtime_digest source_digest approval_timeout_ms maximum_sample_ms maximum_discontinuity_ms drift_ppm qualified_run_ms monotonic_policy suspend_policy)
  @binding ~w(deployment_id owner_id authority_epoch store_boot_epoch elapsed_generation runtime_digest monotonic_origin_ms)
  @request_fields @binding ++
                    ~w(policy_sha256 source_digest reference_epoch reference_started_ms lifecycle_generation lifecycle_started_ms challenge_nonce)
  @utc_scope ~w(deployment_id owner_id authority_epoch store_boot_epoch clock_generation runtime_digest)
  @observation ~w(source_id reference_id source_digest reference_epoch reference_started_ms lifecycle_generation lifecycle_started_ms primary_lower_ms primary_upper_ms continuous_ms)

  @doc "Encodes a complete thirteen-field elapsed policy into its private canonical wire."
  @spec policy_document(term()) :: {:ok, String.t()} | {:error, atom()}
  def policy_document(policy),
    do: protect(fn -> ordered(@policy, @policy_fields, policy!(policy)) end)

  @doc "Decodes only exact canonical elapsed-policy bytes."
  @spec decode_policy(term()) :: {:ok, map()} | {:error, atom()}
  def decode_policy(document),
    do: protect(fn -> decode!(document, @policy, @policy_fields, &policy!/1) end)

  @doc "Encodes a complete fourteen-field approval request, preserving raw signed text."
  @spec request_document(term()) :: {:ok, String.t()} | {:error, atom()}
  def request_document(request),
    do: protect(fn -> ordered(@request, @request_fields, request!(request)) end)

  @doc "Decodes only exact canonical elapsed-request bytes."
  @spec decode_request(term()) :: {:ok, map()} | {:error, atom()}
  def decode_request(document),
    do: protect(fn -> decode!(document, @request, @request_fields, &request!/1) end)

  @doc "Checks the complete seven-field supplied elapsed Store binding."
  @spec binding(term()) :: {:ok, map()} | {:error, atom()}
  def binding(value), do: protect(fn -> binding!(value) end)

  @doc "Checks the complete six-field supplied signed UTC owner scope."
  @spec utc_scope(term()) :: {:ok, map()} | {:error, atom()}
  def utc_scope(value), do: protect(fn -> utc_scope!(value) end)

  @doc "Checks an original qualified ClockSample against the exact supplied UTC scope."
  @spec utc_sample(term(), term()) :: {:ok, map()} | {:error, atom()}
  def utc_sample(sample, scope), do: protect(fn -> utc_sample!(sample, utc_scope!(scope)) end)

  @doc "Checks a native observation's full shape, identity, ordering and policy sample width."
  @spec observation(term(), term()) :: {:ok, map()} | {:error, atom()}
  def observation(value, policy) do
    protect(fn ->
      policy = policy!(policy)
      value = observation!(value)

      require!(
        Enum.all?(~w(source_id reference_id source_digest), &(value[&1] == policy[&1])),
        :routine_clock_unavailable
      )

      width = value["primary_upper_ms"] - value["primary_lower_ms"]
      integer!(width, 0, @maximum)
      require!(width <= policy["maximum_sample_ms"], :routine_clock_unavailable)
      value
    end)
  end

  @doc "Hashes the full approved request's basis array; fresh samples never renew this token."
  @spec elapsed_token(term()) :: {:ok, String.t()} | {:error, atom()}
  def elapsed_token(request) do
    protect(fn ->
      document = ordered("wotex-home.routine-elapsed-basis@1", @request_fields, request!(request))
      "home:elapsed:" <> hash(document)
    end)
  end

  @doc "Commits to the original qualified UTC sample/scope, exchange start and lifecycle."
  @spec utc_token(term(), term(), term(), term()) :: {:ok, String.t()} | {:error, atom()}
  def utc_token(scope, sample, started_ms, observation) do
    protect(fn ->
      scope = utc_scope!(scope)
      sample = utc_sample!(sample, scope)
      integer!(started_ms, 0, @maximum)
      require!(started_ms <= sample["sampled_monotonic_ms"], :routine_clock_unavailable)
      observation = observation!(observation)

      values = [
        "wotex-home.routine-utc-basis@1",
        scope,
        sample["source_id"],
        sample["qualification_digest"],
        sample["sampled_monotonic_ms"],
        sample["utc_lower_ms"],
        sample["utc_upper_ms"],
        sample["maximum_age_ms"],
        sample["drift_ppm"],
        started_ms,
        observation["reference_epoch"],
        observation["lifecycle_generation"],
        Integer.to_string(observation["lifecycle_started_ms"])
      ]

      "home:utc:" <> hash(canonical(values))
    end)
  end

  defp policy!(value) do
    exact!(value, @policy_fields)
    Enum.each(~w(source_id reference_id procedure_ref), &id!(value[&1]))
    Enum.each(~w(qualification_digest runtime_digest source_digest), &hex!(value[&1], 64))
    integer!(value["approval_timeout_ms"], 1, 60_000)
    integer!(value["maximum_sample_ms"], 1, 1000)
    integer!(value["maximum_discontinuity_ms"], 0, 1000)
    integer!(value["drift_ppm"], 0, 1000)
    integer!(value["qualified_run_ms"], 86_400_000, 86_400_000)
    require!(value["monotonic_policy"] == "invalidate_on_discontinuity")
    require!(value["suspend_policy"] == "invalidate_on_lifecycle_change")
    value
  end

  defp binding!(value) do
    exact!(value, @binding)
    Enum.each(~w(deployment_id owner_id runtime_digest), &hex!(value[&1], 64))
    id!(value["store_boot_epoch"])
    Enum.each(~w(authority_epoch elapsed_generation), &integer!(value[&1], 1, @maximum))
    decimal!(value["monotonic_origin_ms"])
    value
  end

  defp request!(value) do
    exact!(value, @request_fields)
    binding!(Map.take(value, @binding))
    Enum.each(~w(policy_sha256 source_digest), &hex!(value[&1], 64))
    hex!(value["reference_epoch"], 32)
    integer!(value["lifecycle_generation"], 1, @maximum)
    first = decimal!(value["reference_started_ms"])
    latest = decimal!(value["lifecycle_started_ms"])
    require!(first <= latest)
    nonce = text!(value["challenge_nonce"])

    decoded =
      case Base.url_decode64(nonce, padding: false) do
        {:ok, bytes} -> bytes
        _ -> fail(:invalid_routine_clock)
      end

    require!(byte_size(decoded) == 32 and Base.url_encode64(decoded, padding: false) == nonce)
    value
  end

  defp observation!(value) do
    exact!(value, @observation)
    Enum.each(~w(source_id reference_id), &id!(value[&1]))
    hex!(value["source_digest"], 64)
    hex!(value["reference_epoch"], 32)
    integer!(value["lifecycle_generation"], 1, @maximum)
    integer!(value["continuous_ms"], 0, @maximum)

    Enum.each(
      ~w(reference_started_ms lifecycle_started_ms primary_lower_ms primary_upper_ms),
      &integer!(value[&1], @minimum, @maximum)
    )

    require!(
      value["reference_started_ms"] <= value["lifecycle_started_ms"] and
        value["lifecycle_started_ms"] <= value["primary_lower_ms"] and
        value["primary_lower_ms"] <= value["primary_upper_ms"],
      :routine_clock_unavailable
    )

    value
  end

  defp utc_scope!(value) do
    exact!(value, @utc_scope)
    Enum.each(~w(deployment_id owner_id runtime_digest), &hex!(value[&1], 64))
    id!(value["store_boot_epoch"])
    Enum.each(~w(authority_epoch clock_generation), &integer!(value[&1], 1, @maximum))
    value
  end

  defp utc_sample!(sample, scope) do
    require!(is_map(sample) and not is_struct(sample) and map_size(sample) == 11)

    Enum.each(Map.values(sample), fn value ->
      if is_integer(value), do: integer!(value, @minimum, @maximum)
    end)

    require!(match?({:ok, _}, ClockSample.encode(sample)))

    require!(
      sample["wall_confidence"] == "qualified" and sample["monotonic_continuous"] and
        sample["boot_epoch"] == scope["store_boot_epoch"] and
        sample["generation"] == scope["clock_generation"],
      :routine_clock_unavailable
    )

    sample
  end

  defp decode!(bytes, format, fields, constructor) do
    require!(is_binary(bytes))
    require!(byte_size(bytes) <= 4096, :routine_clock_limit)
    require!(String.valid?(bytes))
    result = JSON.decode(bytes, {0, 0, nil}, decoders())

    case result do
      {[^format | values], {0, 0, nil}, ""} ->
        require!(length(values) == length(fields))
        value = constructor.(Map.new(Enum.zip(fields, values)))
        require!(ordered(format, fields, value) == bytes)
        value

      _ ->
        fail(:invalid_routine_clock)
    end
  end

  defp decoders do
    [
      object_start: fn _ -> fail(:invalid_routine_clock) end,
      array_start: fn
        {depth, _, _} when depth < 3 -> {depth + 1, 0, []}
        _ -> fail(:routine_clock_limit)
      end,
      array_push: fn
        value, {depth, count, values} when count < 16 -> {depth, count + 1, [value | values]}
        _, _ -> fail(:routine_clock_limit)
      end,
      array_finish: fn {_, _, values}, parent -> {Enum.reverse(values), parent} end,
      string: &text!/1,
      integer: fn bytes ->
        require!(byte_size(bytes) <= 20, :routine_clock_limit)
        integer!(String.to_integer(bytes), 0, @maximum)
      end,
      float: fn _ -> fail(:invalid_routine_clock) end
    ]
  end

  defp exact!(value, fields) do
    require!(
      is_map(value) and not is_struct(value) and map_size(value) == length(fields) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
    )

    Enum.each(Map.values(value), fn
      value when is_binary(value) -> text!(value)
      value when is_integer(value) -> integer!(value, @minimum, @maximum)
      _ -> :ok
    end)
  end

  defp integer!(value, low, high) do
    require!(is_integer(value))
    require!(value >= @minimum and value <= @maximum, :routine_clock_limit)
    require!(value >= low and value <= high)
    value
  end

  defp decimal!(value) do
    text!(value)
    require!(Regex.match?(~r/\A(?:0|-?[1-9][0-9]*)\z/, value))
    require!(byte_size(value) <= 20, :routine_clock_limit)
    integer!(String.to_integer(value), @minimum, @maximum)
  end

  defp text!(value) do
    require!(is_binary(value))
    require!(byte_size(value) <= 128, :routine_clock_limit)
    require!(String.valid?(value))
    value
  end

  defp id!(value), do: require!(Id.valid?(text!(value)))

  defp hex!(value, size),
    do: require!(byte_size(text!(value)) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value))

  defp require!(condition, code \\ :invalid_routine_clock)
  defp require!(true, _), do: :ok
  defp require!(_, code), do: fail(code)
  defp fail(code), do: throw({:routine_clock_error, code})
  defp ordered(format, fields, value), do: JSON.encode!([format | Enum.map(fields, &value[&1])])
  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp canonical(value) when is_map(value),
    do:
      "{" <>
        Enum.map_join(Enum.sort(value), ",", fn {key, item} ->
          JSON.encode!(key) <> ":" <> canonical(item)
        end) <> "}"

  defp canonical(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical/1) <> "]"

  defp canonical(value), do: JSON.encode!(value)

  defp protect(callback) do
    {:ok, callback.()}
  rescue
    _ -> {:error, :invalid_routine_clock}
  catch
    :throw, {:routine_clock_error, code} -> {:error, code}
  end
end
