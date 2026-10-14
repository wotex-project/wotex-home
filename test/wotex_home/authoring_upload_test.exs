defmodule WotexHome.AuthoringUploadTest do
  use ExUnit.Case, async: true
  alias WotexHome.Profiles.AuthoringUpload
  @scope %{"principal_id" => "author:1", "authority_epoch" => 1}
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp input(bytes, changes \\ %{}),
    do:
      Map.merge(
        %{
          "upload_id" => "upload:1",
          "purpose" => "import_payload",
          "payload_bytes" => byte_size(bytes),
          "payload_sha256" => sha(bytes)
        },
        changes
      )

  defp ref(status), do: Map.take(status, ~w(owner_epoch upload_id))

  setup do
    owner = start_supervised!({AuthoringUpload, store_owner: self()})
    %{owner: owner}
  end

  test "full binary ceiling assembles fixed chunks, preserves exact replay and borrows once", c do
    bytes = :binary.copy(<<0, 255>>, 131_072)
    assert {:ok, first} = AuthoringUpload.begin(c.owner, @scope, input(bytes))
    reference = ref(first)

    for offset <- 0..7 do
      position = offset * 32_768
      chunk = binary_part(bytes, position, 32_768)
      assert {:ok, status} = AuthoringUpload.append(c.owner, @scope, reference, position, chunk)
      assert status["next_offset"] == position + 32_768
      assert {:ok, replayed} = AuthoringUpload.append(c.owner, @scope, reference, position, chunk)
      assert Map.delete(replayed, "remaining_ms") == Map.delete(status, "remaining_ms")
      assert replayed["remaining_ms"] <= status["remaining_ms"]
    end

    assert {:ok, ready} = AuthoringUpload.status(c.owner, @scope, "upload:1")
    assert ready["state"] == "ready"

    assert {:ok, %{bytes: ^bytes, token: token}} =
             AuthoringUpload.checkout(c.owner, @scope, reference, "import_payload")

    assert {:error, :authoring_upload_checked_out} =
             AuthoringUpload.cancel(c.owner, @scope, reference)

    assert {:error, :authoring_upload_unavailable} =
             AuthoringUpload.checkout(c.owner, @scope, reference, "import_payload")

    assert :ok = AuthoringUpload.finish(c.owner, token)
    assert {:ok, terminal} = AuthoringUpload.begin(c.owner, @scope, input(bytes))
    assert terminal["state"] == "consumed" and terminal["remaining_ms"] == 0
    assert :sys.get_status(c.owner) |> inspect() |> String.contains?("private_authoring_uploads")
  end

  test "wrong offsets, chunks, purpose, actor and incarnation refuse without advancing", c do
    bytes = String.duplicate("x", 32_769)
    {:ok, first} = AuthoringUpload.begin(c.owner, @scope, input(bytes))
    reference = ref(first)

    assert {:error, :authoring_upload_offset_mismatch} =
             AuthoringUpload.append(c.owner, @scope, reference, 32_768, "x")

    for {offset, chunk} <- [{0, "x"}, {1, String.duplicate("x", 32_768)}, {false, "x"}] do
      assert {:error, :invalid_authoring_upload_chunk} =
               AuthoringUpload.append(c.owner, @scope, reference, offset, chunk)
    end

    assert :not_found =
             AuthoringUpload.status(
               c.owner,
               Map.put(@scope, "principal_id", "author:other"),
               "upload:1"
             )

    assert :not_found =
             AuthoringUpload.status(c.owner, Map.put(@scope, "authority_epoch", 2), "upload:1")

    assert {:error, :authoring_upload_owner_changed} =
             AuthoringUpload.cancel(
               c.owner,
               @scope,
               Map.put(reference, "owner_epoch", String.duplicate("0", 32))
             )

    assert {:error, :authoring_upload_conflict} =
             AuthoringUpload.begin(
               c.owner,
               @scope,
               input(bytes, %{"payload_sha256" => sha("different")})
             )

    {:ok, _} =
      AuthoringUpload.append(c.owner, @scope, reference, 0, String.duplicate("x", 32_768))

    assert {:error, :authoring_upload_conflict} =
             AuthoringUpload.append(c.owner, @scope, reference, 0, String.duplicate("y", 32_768))

    {:ok, ready} = AuthoringUpload.append(c.owner, @scope, reference, 32_768, "x")
    assert ready["state"] == "ready"

    assert {:error, :authoring_upload_unavailable} =
             AuthoringUpload.checkout(c.owner, @scope, reference, "review_original")

    assert {:ok, cancelled} = AuthoringUpload.cancel(c.owner, @scope, reference)
    assert cancelled["state"] == "cancelled"
  end

  test "complete wrong digest invalidates and releases reservation", c do
    declared = input("secret-canary", %{"payload_sha256" => sha("other")})
    {:ok, first} = AuthoringUpload.begin(c.owner, @scope, declared)

    assert {:error, :authoring_upload_digest_mismatch} =
             AuthoringUpload.append(c.owner, @scope, ref(first), 0, "secret-canary")

    assert {:ok, status} = AuthoringUpload.status(c.owner, @scope, "upload:1")
    assert status["state"] == "invalid" and status["remaining_ms"] == 0
    refute inspect(:sys.get_status(c.owner)) =~ "secret-canary"

    refute inspect(
             AuthoringUpload.format_status(%{state: "secret-canary", message: "secret-canary"})
           ) =~ "secret-canary"
  end

  test "reservation, active and original ceilings retain terminal identities" do
    owner =
      start_supervised!(
        {AuthoringUpload, store_owner: self(), limit: 1, byte_limit: 4, original_limit: 2},
        id: :bounded
      )

    {:ok, first} = AuthoringUpload.begin(owner, @scope, input("1234"))

    assert {:error, :authoring_upload_capacity} =
             AuthoringUpload.begin(owner, @scope, input("x", %{"upload_id" => "upload:2"}))

    {:ok, _} = AuthoringUpload.cancel(owner, @scope, ref(first))

    assert {:error, :authoring_upload_capacity} =
             AuthoringUpload.begin(owner, @scope, input("12345", %{"upload_id" => "upload:2"}))

    {:ok, second} =
      AuthoringUpload.begin(owner, @scope, input("1234", %{"upload_id" => "upload:2"}))

    {:ok, _} = AuthoringUpload.cancel(owner, @scope, ref(second))

    assert {:error, :authoring_upload_capacity} =
             AuthoringUpload.begin(owner, @scope, input("x", %{"upload_id" => "upload:3"}))

    assert {:ok, %{"state" => "cancelled"}} = AuthoringUpload.begin(owner, @scope, input("1234"))
  end

  test "borrower death consumes bytes and timeout cannot be renewed" do
    owner = start_supervised!({AuthoringUpload, store_owner: self(), ttl_ms: 100}, id: :short)
    {:ok, first} = AuthoringUpload.begin(owner, @scope, input("x"))
    {:ok, _} = AuthoringUpload.append(owner, @scope, ref(first), 0, "x")

    task =
      Task.async(fn -> AuthoringUpload.checkout(owner, @scope, ref(first), "import_payload") end)

    assert {:ok, _} = Task.await(task)
    assert {:ok, consumed} = AuthoringUpload.status(owner, @scope, "upload:1")
    assert consumed["state"] == "consumed"
    {:ok, _} = AuthoringUpload.begin(owner, @scope, input("x", %{"upload_id" => "upload:2"}))
    Process.sleep(110)

    assert {:ok, expired} =
             AuthoringUpload.begin(owner, @scope, input("x", %{"upload_id" => "upload:2"}))

    assert expired["state"] == "expired" and expired["remaining_ms"] == 0
  end

  test "Store death discards bodies and a new owner cannot resolve an old incarnation" do
    store =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, owner} = AuthoringUpload.start_link(store_owner: store)
    monitor = Process.monitor(owner)
    {:ok, first} = AuthoringUpload.begin(owner, @scope, input("private-canary"))
    {:ok, _} = AuthoringUpload.append(owner, @scope, ref(first), 0, "private-canary")
    send(store, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1000

    assert {:error, :authoring_upload_unavailable} =
             AuthoringUpload.status(owner, @scope, "upload:1")

    replacement = start_supervised!({AuthoringUpload, store_owner: self()}, id: :replacement)
    assert :not_found = AuthoringUpload.status(replacement, @scope, "upload:1")

    assert {:error, :authoring_upload_owner_changed} =
             AuthoringUpload.checkout(replacement, @scope, ref(first), "import_payload")
  end
end
