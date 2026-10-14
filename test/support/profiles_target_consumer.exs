defmodule HomeTargetArchiveTest do
  use ExUnit.Case

  alias WotexHome.Profiles.{
    AuthoringObject,
    ExternalSourceSelection,
    ExternalTarget,
    ExternalTargetPreparation,
    ReaderSelection,
    RetainedSource
  }

  defp vector(family),
    do: JSON.decode!(File.read!("fixtures/external-target-selections.json"))[family]["select"]

  defp source(family) do
    i = JSON.decode!(File.read!("fixtures/external-source-selections.json"))[family]["inputs"]
    r = i["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])
    {:ok, s} = ExternalSourceSelection.new(i["source"], reader, i["channels"])
    s
  end

  defp records(family, input) do
    v =
      if family == "multi",
        do: JSON.decode!(File.read!("fixtures/generic-read-semantics.json"))["multi"]["fixture"],
        else: JSON.decode!(File.read!("fixtures/" <> family <> ".json"))

    objects = input["objects"]

    docs =
      [
        {"envelope", v["envelope"], objects["envelope_ref"]},
        {"profile", v["profile"], objects["profile"]["object_ref"]}
      ] ++
        Enum.zip_with(
          v["definitions"],
          objects["definitions"],
          &{"definition", &1, &2["object_ref"]}
        )

    Enum.map(docs, fn {kind, data, handle} ->
      {:ok, bytes} = Wotex.JSON.encode(data)
      {:ok, object} = AuthoringObject.new(kind, bytes)
      {:ok, summary} = AuthoringObject.summary(object)
      %{"object" => summary, "payload" => bytes, "first_revision" => handle["first_revision"]}
    end)
    |> Enum.sort_by(& &1["object"]["object_digest"])
  end

  test "actual public producer preparation equals independent single and multi-channel vectors" do
    for family <- ~w(temperature research multi) do
      v = vector(family)
      s = source(family)

      assert {:ok, o} =
               ExternalTargetPreparation.build(
                 v["input"],
                 records(family, v["input"]),
                 s,
                 v["outcome"]["artifact_document"]
               )

      assert o == v["outcome"]
      assert {:ok, bytes} = ExternalTarget.encode_outcome(o)
      assert bytes == v["outcome_document"]
      assert {:ok, source_doc} = RetainedSource.encode(s, v["input"]["source_owner_epoch"])
      assert source_doc == o["source_document"]
    end
  end

  test "target reader capture is rebuilt instead of reusing catalogue projection" do
    v = vector("temperature")
    s = source("temperature")
    r = s.inputs["reader"]
    capture = Map.put(r.inputs["capture"], "capture_epoch", String.duplicate("d", 32))

    {:ok, digest} =
      Wotex.Profiles.Capture.digest(
        Map.delete(capture, "digest"),
        hd(r.inputs["installed"]["bindings"]),
        r.inputs["reader_limits"]
      )

    {:ok, reader} =
      ReaderSelection.new(
        r.inputs["installed"],
        Map.put(capture, "digest", digest),
        r.inputs["reader_limits"]
      )

    {:ok, changed} = ExternalSourceSelection.new(s.inputs["source"], reader, s.inputs["channels"])
    input = Map.put(v["input"], "source_selection_sha256", changed.sha256)

    assert {:ok, o} =
             ExternalTargetPreparation.build(
               input,
               records("temperature", input),
               changed,
               v["outcome"]["artifact_document"]
             )

    assert o["artifact_document"] == v["outcome"]["artifact_document"]
    refute o["inspection_document"] == v["outcome"]["inspection_document"]
    refute o["thing_document"] == v["outcome"]["thing_document"]
  end

  test "raw manifest drift, source drift, forged natives and missing actor-selected records refuse preparation" do
    v = vector("temperature")
    s = source("temperature")
    r = records("temperature", v["input"])

    for {input, rs, src, approved} <- [
          {Map.put(v["input"], "source_selection_sha256", String.duplicate("0", 64)), r, s,
           v["outcome"]["artifact_document"]},
          {v["input"], r, Map.put(s, :sha256, String.duplicate("0", 64)),
           v["outcome"]["artifact_document"]},
          {v["input"], tl(r), s, v["outcome"]["artifact_document"]},
          {v["input"], r, s, vector("research")["outcome"]["artifact_document"]}
        ] do
      assert {:error, _} = ExternalTargetPreparation.build(input, rs, src, approved)
    end
  end

  test "historical decoding survives actual optional producer removal" do
    v = vector("multi")
    module = Wotex.JSON
    {^module, beam, path} = :code.get_object_code(module)
    :code.purge(module)
    :code.delete(module)
    # Purging alone permits automatic reloading; remove the selected code path too.
    directory = path |> List.to_string() |> Path.dirname()
    true = :code.del_path(String.to_charlist(directory))

    try do
      refute Code.ensure_loaded?(module)
      assert {:ok, _} = ExternalTarget.decode_outcome(v["outcome_document"])
      assert {:ok, _} = RetainedSource.decode(v["outcome"]["source_document"])
    after
      true = :code.add_patha(String.to_charlist(directory))
      {:module, ^module} = :code.load_binary(module, path, beam)
    end
  end
end
