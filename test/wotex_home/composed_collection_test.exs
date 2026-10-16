defmodule WotexHome.ComposedCollectionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Routines.{Collection, Compiler, Error, Profile}
  alias WotexHome.Rules.ComposedProfile

  @vectors "test/fixtures/routines/composed-profile.json" |> File.read!() |> JSON.decode!()

  test "all 1024 pending originals survive repeated cuts and conflicts precede sixteen-group selection" do
    input = capacity_input()
    assert {:ok, collection} = ComposedProfile.collect(input)
    assert length(collection.data["transitions"]) == 64
    assert length(collection.data["proposals"]) == 1024
    assert length(collection.data["proposal_states"]) == 1024

    dispositions =
      Map.new(collection.data["proposals"], fn proposal ->
        {proposal["step_original"], %{"constraint" => "allowed", "override" => "none"}}
      end)

    assert {:ok, arbitration} = ComposedProfile.arbitrate(collection, dispositions)
    assert length(arbitration["selected"]) == 16
    assert Enum.all?(arbitration["selected"], &(length(&1) == 16))
    assert Enum.count(arbitration["decisions"], &(&1["outcome"] == "conflict")) == 32
    assert Enum.count(arbitration["decisions"], &(&1["outcome"] == "batch-deferred")) == 736
    assert Enum.count(arbitration["decisions"], &(&1["outcome"] == "selected")) == 16

    next = retained(input, collection)
    assert {:ok, repeated} = ComposedProfile.collect(next)
    assert repeated.data["proposals"] === collection.data["proposals"]
    assert repeated.data["proposal_states"] === collection.data["proposal_states"]
    assert Enum.all?(repeated.data["transitions"], &(&1["result"]["proposals"] == []))
    assert {:ok, again} = ComposedProfile.arbitrate(repeated, dispositions)
    assert again["selected"] === arbitration["selected"]
    assert again["decisions"] === arbitration["decisions"]

    missing = put_in(next, ["entries", Access.at(0), "event"], nil)
    assert {:error, %Error{code: :incomplete_run_continuation}} = ComposedProfile.collect(missing)

    omitted = update_in(next, ["entries"], &tl/1)
    assert {:error, %Error{code: :incomplete_collection}} = ComposedProfile.collect(omitted)
    assert {:error, %Error{}} = ComposedProfile.arbitrate(repeated, %{})
  end

  test "a separately compiled 1023 bound refuses the complete 1024 contributors" do
    {:ok, selection} = ComposedProfile.new()
    {:ok, profile} = Profile.new(%{selection.profile.data | "pending_work" => 1023})
    input = capacity_input(profile)

    assert {:error, %Error{code: :pending_work_bound}} =
             Collection.evaluate(input, profile, selection.limits)

    assert {:error, %Error{code: :invalid_profile}} =
             ComposedProfile.new(profile, selection.limits)

    assert {:error, %Error{code: :stale_or_forged_program}} = ComposedProfile.collect(input)
  end

  test "legacy newly-emitted collections cannot masquerade as complete pending calculations" do
    input = capacity_input(nil, 1)
    {:ok, selection} = ComposedProfile.new()
    legacy_input = Map.delete(input, "format")
    {:ok, legacy} = Collection.evaluate(legacy_input, selection.profile, selection.limits)

    assert {:error, %Error{code: :unsupported_decision_scope}} =
             ComposedProfile.collect(legacy_input)

    assert {:error, %Error{code: :unsupported_decision_scope}} =
             ComposedProfile.arbitrate(legacy, %{})

    assert {:ok, collection} = ComposedProfile.collect(input)
    forged = Map.put(collection, :authority, true)
    assert {:error, %Error{}} = ComposedProfile.arbitrate(forged, %{})
  end

  defp capacity_input(profile \\ nil, count \\ 64) do
    {:ok, selection} = ComposedProfile.new()
    profile = profile || selection.profile
    vector = hd(@vectors["cases"])

    programs =
      Enum.map(1..count, fn index ->
        target = if index == 64, do: 1, else: index

        context =
          put_in(vector["context"], ["bindings", "output", "thing_id"], "urn:fixture:#{target}")

        context =
          put_in(
            context,
            ["bindings", "output", "resource_roles", "target"],
            "urn:fixture:#{target}"
          )

        steps = %{
          "id" => "all",
          "kind" => "parallel",
          "branches" =>
            Enum.map(0..3, fn group ->
              %{
                "id" => "group:#{group}",
                "kind" => "parallel",
                "branches" =>
                  Enum.map(0..3, fn leaf ->
                    %{
                      "id" => "effect:#{group}:#{leaf}",
                      "kind" => "effect",
                      "binding" => "output",
                      "input" => index == 64,
                      "completion" => "reported_match"
                    }
                  end)
              }
            end)
        }

        source = %{vector["source"] | "id" => "member:#{index}", "steps" => steps}
        {:ok, program} = Compiler.compile(source, context, profile, selection.limits)
        program.data
      end)

    ids = Enum.map(programs, & &1["ir_digest"])

    entries =
      Enum.map(programs, fn program ->
        binding = program["context"]["bindings"]["output"]
        target = binding["thing_id"]

        %{
          "program" => program,
          "event" => %{
            "kind" => "manual",
            "program_digest" => program["ir_digest"],
            "original" => "original:" <> program["source"]["id"]
          },
          "prior" => %{"original" => nil, "busy" => nil, "edge" => nil},
          "snapshot" => %{
            "id" => "fixture:cut",
            "membership_generation" => "fixture:members",
            "active_programs" => ids,
            "resource_revisions" => %{target => 1},
            "facts" => %{"output" => nil},
            "binding_bases" => %{
              "output" => %{
                "profile_digest" => binding["basis"]["semantic_digest"],
                "source_id" => target,
                "source_epoch" => "connection:one",
                "source_time_basis" => nil
              }
            }
          }
        }
      end)

    %{
      "format" => "wotex.routines.collection-input@2",
      "membership" => %{"generation" => "fixture:members", "programs" => ids},
      "entries" => entries,
      "time" => %{
        "format" => "wotex.routines.time@2",
        "epoch" => "fixture:boot",
        "clock_generation" => "elapsed:one",
        "elapsed_ms" => 20,
        "utc_generation" => nil,
        "utc_low_ms" => nil,
        "utc_high_ms" => nil
      }
    }
  end

  defp retained(input, collection) do
    results = Map.new(collection.data["transitions"], &{&1["program_digest"], &1["result"]})

    update_in(input, ["entries"], fn entries ->
      Enum.map(entries, fn entry ->
        previous = results[entry["program"]["ir_digest"]]
        run = previous["run"]

        %{
          entry
          | "event" => %{
              "kind" => "resume",
              "original" => run["original"],
              "program_digest" => run["program_digest"]
            },
            "prior" => %{"original" => run, "busy" => nil, "edge" => previous["edge"]}
        }
      end)
    end)
  end
end
