defmodule HomeSourceOwnerArchiveTest do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Profiles.{ExternalSourceOwner, ExternalSourceSelection, ReaderSelection}

  defp source(family \\ "temperature", overrides \\ %{}) do
    v = JSON.decode!(File.read!("fixtures/external-source-selections.json"))[family]
    i = v["inputs"]
    r = i["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])

    {:ok, value} =
      ExternalSourceSelection.new(Map.merge(i["source"], overrides), reader, i["channels"])

    value
  end

  defp original(operation \\ "selection:1"),
    do: %{
      "authority_epoch" => 1,
      "operation_id" => operation,
      "input_sha256" => String.duplicate("a", 64)
    }

  defp start(options \\ []),
    do: start_supervised!({ExternalSourceOwner, [publisher: self()] ++ options})

  defp epoch(owner), do: (ExternalSourceOwner.catalogue(owner) |> elem(1))["owner_epoch"]

  defp hold(owner, op \\ "selection:1"),
    do:
      ExternalSourceOwner.hold(
        owner,
        "operator:1",
        original(op),
        "source:independent",
        epoch(owner)
      )

  test "original hold, checkout, validate and finish preserve exact deadline and private scope" do
    owner = start()
    value = source()
    assert {:ok, published} = ExternalSourceOwner.publish(owner, value)
    assert published["data"] == value.data
    refute JSON.encode!(published) =~ value.inputs["source"]["stable_id"]
    assert {:ok, lease} = hold(owner)
    assert {:ok, ^lease} = hold(owner)

    assert {:ok, borrowed} =
             ExternalSourceOwner.checkout(owner, "operator:1", lease["token"], original())

    assert borrowed.selection == value and borrowed.guard.checkout_pid == self()
    assert {:ok, ^published} = ExternalSourceOwner.publish(owner, value)

    assert {:ok, ^borrowed} =
             ExternalSourceOwner.checkout(owner, "operator:1", lease["token"], original())

    assert {:ok, guard} =
             ExternalSourceOwner.validate(owner, "operator:1", lease["token"], original(), self())

    assert guard == borrowed.guard
    assert :not_found = ExternalSourceOwner.status(owner, "other:1", 1, "selection:1")
    assert :not_found = ExternalSourceOwner.checkout(owner, "other:1", lease["token"], original())

    assert {:error, :external_source_conflict} =
             ExternalSourceOwner.hold(
               owner,
               "operator:1",
               Map.put(original(), "input_sha256", String.duplicate("b", 64)),
               "source:independent",
               epoch(owner)
             )

    assert {:error, :external_source_owner_changed} =
             ExternalSourceOwner.hold(
               owner,
               "operator:1",
               original(),
               "source:independent",
               String.duplicate("0", 32)
             )

    assert :ok = ExternalSourceOwner.finish(owner, "operator:1", lease["token"], original())
    assert :ok = ExternalSourceOwner.finish(owner, "operator:1", lease["token"], original())
    assert {:ok, %{"state" => "consumed"}} = hold(owner)

    assert {:error, :external_source_retired} =
             ExternalSourceOwner.validate(owner, "operator:1", lease["token"], original(), self())

    state = :sys.get_state(owner)

    assert Enum.all?(state.entries, fn {_, e} ->
             e.selection == nil and e.monitor == nil and e.deadline == nil
           end)
  end

  test "foreign publisher and failed generation/capacity changes preserve current sources and leases" do
    owner = start(source_limit: 1)
    value = source()
    assert {:ok, _} = ExternalSourceOwner.publish(owner, value)
    assert {:ok, lease} = hold(owner)

    assert {:error, :external_source_publisher_denied} =
             Task.async(fn -> ExternalSourceOwner.publish(owner, %{}) end) |> Task.await()

    assert {:error, :invalid_external_source} =
             ExternalSourceOwner.publish(owner, Map.put(value, :extra, true))

    assert {:error, :stale_external_source_generation} =
             ExternalSourceOwner.publish(owner, source("research"))

    assert {:error, :external_source_capacity} =
             ExternalSourceOwner.publish(
               owner,
               source("research", %{"source_ref" => "source:other"})
             )

    assert {:ok, ^lease} = hold(owner)
    assert {:ok, %{"sources" => [current]}} = ExternalSourceOwner.catalogue(owner)
    assert current["source_selection_sha256"] == value.sha256
  end

  test "source byte capacity refuses actual checked input without publication" do
    owner = start(max_bytes: 1)
    assert {:error, :external_source_capacity} = ExternalSourceOwner.publish(owner, source())
    assert {:ok, %{"sources" => []}} = ExternalSourceOwner.catalogue(owner)
    assert :not_found = hold(owner)
  end

  test "actual current byte boundary and maximum source count are inclusive" do
    value = source()
    i = value.inputs

    {:ok, bytes} =
      Wotex.JSON.encode(%{
        "source" => i["source"],
        "reader" => i["reader"].inputs,
        "channels" => i["channels"]
      })

    owner = start(max_bytes: byte_size(bytes))
    assert {:ok, _} = ExternalSourceOwner.publish(owner, value)
    assert {:ok, _} = ExternalSourceOwner.publish(owner, value)

    assert {:error, :external_source_capacity} =
             ExternalSourceOwner.publish(
               owner,
               source("temperature", %{"source_ref" => "source:other"})
             )

    stop_supervised(ExternalSourceOwner)
    owner = start()

    for n <- 1..32 do
      assert {:ok, _} =
               ExternalSourceOwner.publish(
                 owner,
                 source("temperature", %{
                   "source_ref" => "source:#{String.pad_leading(Integer.to_string(n), 2, "0")}"
                 })
               )
    end

    assert {:error, :external_source_capacity} =
             ExternalSourceOwner.publish(
               owner,
               source("temperature", %{"source_ref" => "source:over"})
             )

    assert {:ok, %{"sources" => sources}} = ExternalSourceOwner.catalogue(owner)
    assert length(sources) == 32 and sources == Enum.sort_by(sources, & &1["source_ref"])
  end

  test "configured publisher death stops the actual owner and discards its custody" do
    publisher =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, owner} = ExternalSourceOwner.start_link(publisher: publisher)
    monitor = Process.monitor(owner)
    Process.exit(publisher, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1000
    refute Process.alive?(owner)
  end

  test "replacement invalidates pending and checked-out originals without renewal or private retention" do
    owner = start()
    assert {:ok, _} = ExternalSourceOwner.publish(owner, source())
    assert {:ok, first} = hold(owner)
    assert {:ok, second} = hold(owner, "selection:2")

    assert {:ok, _} =
             ExternalSourceOwner.checkout(
               owner,
               "operator:1",
               second["token"],
               original("selection:2")
             )

    assert {:ok, _} =
             ExternalSourceOwner.publish(owner, source("research", %{"source_generation" => 2}))

    for {lease, op} <- [{first, "selection:1"}, {second, "selection:2"}] do
      assert {:ok, %{"state" => "invalidated", "token" => token}} = hold(owner, op)
      assert token == lease["token"]

      assert {:error, :external_source_retired} =
               ExternalSourceOwner.validate(owner, "operator:1", token, original(op), self())
    end

    assert {:ok, %{"state" => "pending"}} = hold(owner, "selection:3")
    assert Enum.count(:sys.get_state(owner).entries, fn {_, e} -> e.monitor != nil end) == 0
  end

  test "checked-out caller ownership, death and cancellation cannot recycle a snapshot" do
    owner = start(lease_limit: 1)
    assert {:ok, _} = ExternalSourceOwner.publish(owner, source())
    assert {:ok, lease} = hold(owner)
    parent = self()

    borrower =
      spawn(fn ->
        send(
          parent,
          {:borrowed,
           ExternalSourceOwner.checkout(owner, "operator:1", lease["token"], original())}
        )

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:borrowed, {:ok, borrowed}}

    assert {:error, :external_source_busy} =
             ExternalSourceOwner.checkout(owner, "operator:1", lease["token"], original())

    assert {:error, :external_source_busy} =
             ExternalSourceOwner.finish(owner, "operator:1", lease["token"], original())

    assert {:error, :external_source_busy} =
             ExternalSourceOwner.cancel(owner, "operator:1", 1, "selection:1")

    expected_guard = borrowed.guard

    assert {:ok, ^expected_guard} =
             ExternalSourceOwner.validate(
               owner,
               "operator:1",
               lease["token"],
               original(),
               borrower
             )

    monitor = Process.monitor(borrower)
    Process.exit(borrower, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^borrower, :killed}
    assert {:ok, %{"state" => "cancelled"}} = await_status(owner, "selection:1", "cancelled")

    assert {:error, :external_source_retired} =
             ExternalSourceOwner.checkout(owner, "operator:1", lease["token"], original())

    assert {:ok, next} = hold(owner, "selection:2")
    assert :ok = ExternalSourceOwner.cancel(owner, "operator:1", 1, "selection:2")
    assert :ok = ExternalSourceOwner.cancel(owner, "operator:1", 1, "selection:2")
    assert {:ok, %{"state" => "cancelled", "token" => token}} = hold(owner, "selection:2")
    assert token == next["token"]
  end

  test "pending and checked-out expiry releases slots without extending original deadlines" do
    owner = start(ttl_ms: 100, lease_limit: 2)
    assert {:ok, _} = ExternalSourceOwner.publish(owner, source())
    assert {:ok, a} = hold(owner)
    assert {:ok, b} = hold(owner, "selection:2")

    assert {:ok, _} =
             ExternalSourceOwner.checkout(
               owner,
               "operator:1",
               b["token"],
               original("selection:2")
             )

    Process.sleep(130)

    assert {:ok, %{"state" => "expired"}} =
             ExternalSourceOwner.status(owner, "operator:1", 1, "selection:1")

    assert {:ok, %{"state" => "expired"}} =
             ExternalSourceOwner.status(owner, "operator:1", 1, "selection:2")

    assert {:error, :external_source_retired} =
             ExternalSourceOwner.checkout(owner, "operator:1", a["token"], original())

    assert {:ok, _} = hold(owner, "selection:3")

    assert {:error, :external_source_retired} =
             ExternalSourceOwner.cancel(owner, "operator:1", 1, "selection:1")
  end

  test "the timer retires abandoned custody without a status request" do
    owner = start(ttl_ms: 100)
    assert {:ok, _} = ExternalSourceOwner.publish(owner, source())
    assert {:ok, lease} = hold(owner)

    assert {:ok, _} =
             ExternalSourceOwner.checkout(owner, "operator:1", lease["token"], original())

    Process.sleep(250)
    # sys.get_state does not invoke the owner's call-time expiry path.
    entry = :sys.get_state(owner).entries[{"operator:1", 1, "selection:1"}]
    assert entry.state == :expired and entry.selection == nil and entry.monitor == nil
    assert elem(Process.info(owner, :monitors), 1) == [{:process, self()}]
  end

  test "removed producer cannot prevent original metadata, guarded checkout or retirement" do
    owner = start()
    value = source()
    assert {:ok, _} = ExternalSourceOwner.publish(owner, value)
    assert {:ok, lease} = hold(owner)
    path = :code.which(Wotex.JSON) |> List.to_string() |> Path.dirname()
    true = Code.delete_path(path)
    :code.purge(Wotex.JSON)
    :code.delete(Wotex.JSON)

    try do
      refute Code.ensure_loaded?(Wotex.JSON)
      assert {:ok, ^lease} = hold(owner)

      assert {:ok, _} =
               ExternalSourceOwner.checkout(owner, "operator:1", lease["token"], original())

      assert {:error, :profiles_producer_unavailable} = ExternalSourceOwner.publish(owner, value)
      assert :ok = ExternalSourceOwner.finish(owner, "operator:1", lease["token"], original())
      assert {:ok, %{"state" => "consumed"}} = hold(owner)
      assert {:ok, %{"sources" => [_]}} = ExternalSourceOwner.catalogue(owner)
    after
      true = Code.prepend_path(path)
      assert Code.ensure_loaded?(Wotex.JSON)
    end
  end

  test "1024 retired originals preserve replay and refuse an additional scope" do
    owner = start(lease_limit: 1)
    assert {:ok, _} = ExternalSourceOwner.publish(owner, source())

    for n <- 1..1024 do
      op = "selection:#{n}"
      assert {:ok, _} = hold(owner, op)
      assert :ok = ExternalSourceOwner.cancel(owner, "operator:1", 1, op)
    end

    assert {:error, :external_source_capacity} = hold(owner, "selection:over")
    assert {:ok, %{"state" => "cancelled"}} = hold(owner)
    assert map_size(:sys.get_state(owner).entries) == 1024
  end

  test "owner restart changes epoch and cannot revive tokens even with identical republished source" do
    owner = start()
    value = source()
    assert {:ok, _} = ExternalSourceOwner.publish(owner, value)
    old = epoch(owner)
    assert {:ok, lease} = hold(owner)
    stop_supervised(ExternalSourceOwner)
    owner = start()
    refute epoch(owner) == old
    assert {:ok, _} = ExternalSourceOwner.publish(owner, value)

    assert {:error, :external_source_owner_changed} =
             ExternalSourceOwner.hold(owner, "operator:1", original(), "source:independent", old)

    assert :not_found =
             ExternalSourceOwner.checkout(owner, "operator:1", lease["token"], original())
  end

  defp await_status(owner, operation, wanted, tries \\ 20) do
    result = ExternalSourceOwner.status(owner, "operator:1", 1, operation)

    if match?({:ok, %{"state" => ^wanted}}, result) or tries == 0,
      do: result,
      else:
        (
          Process.sleep(5)
          await_status(owner, operation, wanted, tries - 1)
        )
  end
end
