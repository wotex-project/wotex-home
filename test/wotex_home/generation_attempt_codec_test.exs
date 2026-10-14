defmodule WotexHome.GenerationAttemptCodecTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias WotexHome.Profiles.{
    AuthoringAssessment,
    AuthoringContract,
    GenerationAttempt,
    GenerationProvider,
    GenerationRunner,
    ProducerIdentity
  }

  defmodule Provider do
    @moduledoc false

    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_call({:generate_profile, document, output}, from, state) do
      send(state[:observer], {:provider_call, self(), from, document, output})
      if state[:hold], do: {:noreply, state}, else: {:reply, state[:result], state}
    end
  end

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  defp contract(family) do
    {:ok, producer} = ProducerIdentity.current()

    installed =
      Map.take(fixture(family), ~w(bindings contracts home_contracts))
      |> Map.put("producer", producer)

    {:ok, contract} =
      AuthoringContract.export(installed, fixture("authoring-mechanics")[family]["limits"])

    contract
  end

  defp provider(opts) do
    pid = start_supervised!({Provider, Keyword.put(opts, :observer, self())})
    identity = fixture("generation-preparations")["temperature"]["policy"]["provider"]
    {:ok, provider} = GenerationProvider.new(identity, pid)
    provider
  end

  test "independent ordered originals, receipts, input bytes and object operation IDs" do
    for family <- ~w(temperature research) do
      v = fixture("generation-attempts")[family]
      assert {:ok, v["document"]} == GenerationAttempt.encode(v["request"])
      assert {:ok, v["request"]} == GenerationAttempt.decode(v["document"])
      assert {:ok, v["receipt_document"]} == GenerationAttempt.encode_receipt(v["receipt"])
      assert {:ok, v["receipt"]} == GenerationAttempt.decode_receipt(v["receipt_document"])
      assert {:ok, v["result_document"]} == GenerationAttempt.encode_result(v["result"])
      assert {:ok, v["result"]} == GenerationAttempt.decode_result(v["result_document"])

      assert {:ok, v["handoff_document"]} ==
               GenerationAttempt.provider_document(
                 fixture("generation-inputs")[family]["document"],
                 nil,
                 1_048_576
               )

      for kind <- ~w(draft bundle),
          do:
            assert(
              GenerationAttempt.object_operation("author:fixture", 1, "attempt:fixture", kind) ==
                v["object_operations"][kind]
            )
    end
  end

  test "closed attempt shapes, integer bounds and historical ceilings" do
    v = fixture("generation-attempts")["temperature"]

    for mutation <- [
          %{"extra" => 1},
          %{"attempt" => 1.0},
          %{"attempt" => 4},
          %{"attempt" => 2},
          %{"repair_export" => true},
          %{"authority_epoch" => 0},
          %{"expected_revision" => 9_223_372_036_854_775_808},
          %{"operation_id" => "x y"}
        ] do
      assert {:error, :invalid_generation_attempt} =
               GenerationAttempt.encode(Map.merge(v["request"], mutation))
    end

    assert {:error, :invalid_generation_attempt} = GenerationAttempt.decode(" " <> v["document"])

    assert {:error, :invalid_generation_attempt} =
             GenerationAttempt.decode("{\"authority_epoch\":1}")

    assert {:error, :invalid_generation_attempt} =
             GenerationAttempt.decode(String.replace(v["document"], ",1,null,", ",1.0,null,"))

    assert {:error, :authoring_limit} = GenerationAttempt.decode(String.duplicate("x", 2049))

    assert {:error, :authoring_limit} =
             GenerationAttempt.decode_result(String.duplicate("x", 131_073))

    repair =
      Map.merge(v["request"], %{
        "attempt" => 2,
        "previous_operation_id" => "attempt:fixture",
        "repair_export" => true
      })

    assert {:ok, bytes} = GenerationAttempt.encode(repair)
    assert {:ok, ^repair} = GenerationAttempt.decode(bytes)
  end

  test "feedback is derived from the same invalid draft and obeys total input ceiling" do
    bytes = "{\"untrusted_instruction\":\"select new source\"}"
    {:ok, assessment} = AuthoringAssessment.assess(bytes, contract("temperature"), nil)
    assert assessment.data["disposition"] == "invalid"
    projection = fixture("generation-inputs")["temperature"]["document"]

    assert {:ok, document} =
             GenerationAttempt.provider_document(projection, {bytes, assessment.data}, 1_048_576)

    assert ["wotex-home.generation-attempt-input@1", initial, [^bytes, report]] =
             JSON.decode!(document)

    assert initial == JSON.decode!(projection)

    assert {:ok, encoded} =
             WotexHome.Profiles.AuthoringCandidate.encode_assessment(assessment.data)

    assert report == JSON.decode!(encoded)

    assert {:ok, ^document} =
             GenerationAttempt.provider_document(
               projection,
               {bytes, assessment.data},
               byte_size(document)
             )

    assert {:error, :authoring_limit} =
             GenerationAttempt.provider_document(
               projection,
               {bytes, assessment.data},
               byte_size(document) - 1
             )

    assert {:error, :invalid_generation_attempt} =
             GenerationAttempt.provider_document(
               projection,
               {bytes <> " ", assessment.data},
               1_048_576
             )

    result = %{
      "disposition" => "candidate",
      "reason" => nil,
      "draft_ref" => %{"object_digest" => String.duplicate("a", 64), "first_revision" => 12},
      "bundle_ref" => nil,
      "assessment" => assessment.data
    }

    assert {:ok, r} = GenerationAttempt.encode_result(result)
    assert {:ok, ^result} = GenerationAttempt.decode_result(r)

    assert {:error, :invalid_generation_attempt} =
             GenerationAttempt.encode_result(Map.put(result, "draft_ref", nil))

    assert {:error, :invalid_generation_attempt} =
             GenerationAttempt.encode_result(
               GenerationAttempt.failure("withdrawn", "private exception")
             )
  end

  test "native provider identity shares the frozen policy domain and rejects forged capabilities" do
    p = provider(result: {:ok, "{}"})
    assert {:ok, p.provider_sha256} == GenerationProvider.identity(p.provider)

    assert p.provider_sha256 ==
             fixture("generation-preparations")["temperature"]["provider_sha256"]

    assert :ok = GenerationProvider.installation([p])
    assert {:ok, ^p} = GenerationProvider.select([p], p.provider_sha256)
    assert {:error, :invalid_generation_provider} = GenerationProvider.new(p.provider, __MODULE__)

    assert {:error, :invalid_generation_provider} =
             GenerationProvider.validate(Map.put(p, :provider_sha256, String.duplicate("0", 64)))

    assert {:error, :invalid_generation_provider} =
             GenerationProvider.validate(Map.put(p, :extra, true))

    assert {:error, :invalid_generation_provider} = GenerationProvider.installation([p, p])

    assert {:error, :invalid_generation_provider} =
             GenerationProvider.installation([p | :improper])

    refute inspect(p, limit: :infinity) =~ "#PID"
  end

  test "worker sends one closed call and returns only on the exact owner channel" do
    p = provider(result: {:ok, "{\"draft\":true}"})
    token = make_ref()
    assert {:ok, runner} = GenerationRunner.start(p, "private projection", 20, 2000, token)
    assert_receive {:provider_call, pid, {helper, _}, "private projection", 20}
    assert pid == p.pid and helper != self() and helper != runner
    assert_receive {:generation_result, ^runner, ^token, {:ok, "{\"draft\":true}"}}
    refute_receive {:provider_call, _, _, _, _}, 20
  end

  test "worker bounds output and strips arbitrary provider response diagnostics" do
    for response <- [
          {:ok, ""},
          {:ok, String.duplicate("x", 11)},
          {:ok, <<255>>},
          {:error, "private endpoint credential"},
          %{"untrusted" => true}
        ] do
      p = provider(result: response)
      token = make_ref()
      assert {:ok, runner} = GenerationRunner.start(p, "input", 10, 1000, token)
      assert_receive {:generation_result, ^runner, ^token, {:error, :invalid_response}}
      stop_supervised!(Provider)
    end
  end

  test "timeout and cancellation kill helpers without retry or model-stop claims" do
    p = provider(hold: true)
    token = make_ref()
    assert {:ok, runner} = GenerationRunner.start(p, "canary-private-input", 100, 50, token)
    assert_receive {:provider_call, _, {helper, _}, _, _}
    helper_monitor = Process.monitor(helper)
    refute inspect(:sys.get_status(runner), limit: :infinity) =~ "canary-private-input"
    assert_receive {:generation_result, ^runner, ^token, {:error, :deadline_expired}}, 1000
    assert_receive {:DOWN, ^helper_monitor, :process, ^helper, _}, 1000
    token = make_ref()
    assert {:ok, runner} = GenerationRunner.start(p, "input", 100, 2000, token)
    assert_receive {:provider_call, _, {helper, _}, _, _}
    monitor = Process.monitor(runner)
    GenerationRunner.cancel(runner)
    assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}
    refute Process.alive?(helper)
    refute_receive {:generation_result, ^runner, ^token, _}, 20
  end

  test "owner and runner death retire the linked helper and do not retry" do
    p = provider(hold: true)

    owner =
      spawn(fn ->
        {:ok, _runner} = GenerationRunner.start(p, "input", 100, 2000, make_ref())

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:provider_call, _, {helper, _}, _, _}
    helper_monitor = Process.monitor(helper)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^helper_monitor, :process, ^helper, _}, 1000
    {:ok, runner} = GenerationRunner.start(p, "input", 100, 2000, make_ref())
    assert_receive {:provider_call, _, {helper, _}, _, _}
    helper_monitor = Process.monitor(helper)
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^helper_monitor, :process, ^helper, _}, 1000
    refute_receive {:provider_call, _, _, _, _}, 20
  end
end
