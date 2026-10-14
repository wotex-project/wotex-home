defmodule WotexHome.OpenAIWireTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias WotexHome.Profiles.OpenAIWire
  defp fixture, do: JSON.decode!(File.read!("test/fixtures/profiles/openai-generation.json"))

  test "independent API bytes preserve original document and raw drafts for both families" do
    for family <- ~w(temperature research) do
      v = fixture()[family]
      assert {:ok, v["request_document"]} == OpenAIWire.request(v["document"], v["model"], 8192)

      assert {:ok, v["draft_bytes"]} ==
               OpenAIWire.response(v["response_document"], v["model"], 262_144)

      body = JSON.decode!(v["request_document"])
      assert body["tools"] == [] and body["tool_choice"] == "none"
      assert body["store"] == false and body["stream"] == false and body["background"] == false
      assert body["input"] == [%{"role" => "user", "content" => v["document"]}]
      refute Map.has_key?(body, "previous_response_id")

      assert Base.encode16(:crypto.hash(:sha256, v["request_document"]), case: :lower) ==
               v["request_sha256"]
    end
  end

  test "raw draft spelling and inclusive output boundary are unchanged" do
    v = fixture()["temperature"]

    for draft <- [
          ~s({"value":1.2300,"scientific":1e2,"negative_zero":-0.0}),
          String.duplicate("x", 262_144)
        ] do
      response =
        put_in(
          v["response"],
          ["output", Access.at(0), "content", Access.at(0), "text"],
          JSON.encode!(%{"draft" => draft})
        )

      assert {:ok, ^draft} =
               OpenAIWire.response(JSON.encode!(response), v["model"], byte_size(draft))

      assert {:error, :invalid_response} =
               OpenAIWire.response(JSON.encode!(response), v["model"], byte_size(draft) - 1)
    end
  end

  test "closed originals refuse wrong format, noncanonical bytes and explicit model/token bounds" do
    v = fixture()["temperature"]

    for document <- [
          "",
          <<255>>,
          "[]",
          JSON.encode!(["wrong", %{}, nil]),
          " " <> v["document"],
          String.duplicate("x", 1_048_577)
        ],
        do: assert({:error, :invalid_response} = OpenAIWire.request(document, v["model"], 8192))

    for model <- [nil, "", "model with spaces"],
        do: assert({:error, :invalid_response} = OpenAIWire.request(v["document"], model, 8192))

    for tokens <- [0, true, 1.0, 65537],
        do:
          assert(
            {:error, :invalid_response} = OpenAIWire.request(v["document"], v["model"], tokens)
          )
  end

  test "response refuses mismatched identity, tools, intermediate messages and malformed wrappers" do
    v = fixture()["temperature"]
    original = v["response"]

    mutations = [
      Map.put(original, "model", "other:model"),
      Map.delete(original, "error"),
      Map.put(original, "object", "other"),
      Map.put(original, "output", []),
      Map.put(original, "output", original["output"] ++ original["output"]),
      Map.put(original, "output", [
        %{"type" => "function_call", "name" => "activate"} | original["output"]
      ]),
      put_in(original, ["output", Access.at(0), "phase"], "commentary"),
      put_in(original, ["output", Access.at(0), "status"], "in_progress"),
      put_in(original, ["output", Access.at(0), "content", Access.at(0), "annotations"], [
        %{"file" => "private"}
      ]),
      put_in(
        original,
        ["output", Access.at(0), "content", Access.at(0), "text"],
        ~s({"draft":"a","extra":true})
      ),
      put_in(
        original,
        ["output", Access.at(0), "content", Access.at(0), "text"],
        ~s({"draft":"a","draft":"b"})
      )
    ]

    for response <- mutations,
        do:
          assert(
            {:error, :invalid_response} =
              OpenAIWire.response(JSON.encode!(response), v["model"], 262_144)
          )

    final = put_in(original, ["output", Access.at(0), "phase"], "final_answer")

    assert {:ok, v["draft_bytes"]} ==
             OpenAIWire.response(JSON.encode!(final), v["model"], 262_144)

    reasoning =
      Map.put(original, "output", [%{"type" => "reasoning", "summary" => []} | original["output"]])

    assert {:ok, v["draft_bytes"]} ==
             OpenAIWire.response(JSON.encode!(reasoning), v["model"], 262_144)

    for bytes <- [
          "",
          <<255>>,
          String.duplicate("x", 4_194_305),
          "{\"model\":\"a\",\"model\":\"b\"}"
        ] do
      assert {:error, :invalid_response} = OpenAIWire.response(bytes, v["model"], 262_144)
    end
  end

  test "service refusal/incomplete/failed states discard raw service diagnostics" do
    v = fixture()["temperature"]

    for status <- ~w(failed incomplete queued in_progress cancelled) do
      data =
        v["response"]
        |> Map.put("status", status)
        |> Map.put("error", %{"private-canary" => "discard"})

      assert {:error, :unavailable} = OpenAIWire.response(JSON.encode!(data), v["model"], 262_144)
    end

    refusal =
      put_in(v["response"], ["output", Access.at(0), "content"], [
        %{"type" => "refusal", "refusal" => "private-canary"}
      ])

    assert {:error, :unavailable} =
             OpenAIWire.response(JSON.encode!(refusal), v["model"], 262_144)
  end
end
