defmodule WotexHome.OrdinaryRecoveryBoundaryTest do
  use ExUnit.Case
  alias WotexHome.{Authority, Durable.Store}
  import ExUnit.CaptureLog

  test "ordinary Store rejects trusted recovery calls without terminating or logging custody" do
    temporary = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "woh-recovery-boundary-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    store = start_supervised!({Store, path: Path.join(root, "home.sqlite")})
    authority = Authority.new(store: store)
    secret = :crypto.strong_rand_bytes(32)

    log =
      capture_log(fn ->
        assert {:error, :recovery_operation_required} =
                 Authority.accept_controller_transfer(
                   authority,
                   "review:unavailable",
                   secret,
                   %{}
                 )

        assert {:error, :recovery_operation_required} =
                 Authority.transfer_acceptance_status(authority, secret, %{})
      end)

    assert log == ""
    assert Process.alive?(store)
    assert {:ok, %{writable: true, dispatch_enabled: false}} = Store.health(store)
    assert {:ok, 0} = Store.revision(store)
  end
end
