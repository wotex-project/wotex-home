defmodule WotexHome.Firmware.BoardSnapshotTest do
  @moduledoc false

  use ExUnit.Case

  alias WotexHome.Durable.Store
  alias WotexHome.Firmware.BoardSnapshot

  defmodule GoodRuntime do
    @moduledoc false

    def mix_target, do: :rpi4
    def firmware_slots, do: %{active: "b", next: "a"}
    def firmware_validation_status, do: :unvalidated
  end

  defmodule UnknownRuntime do
    @moduledoc false

    def mix_target, do: :rpi4
    def firmware_slots, do: %{active: "b", next: "a"}
    def firmware_validation_status, do: :unknown
  end

  defmodule WrongTarget do
    @moduledoc false

    def mix_target, do: :host
  end

  test "captures actual Store state and preserves unvalidated versus unknown" do
    directory = Path.join(System.tmp_dir!(), "home-board-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, store} = Store.start_link(path: Path.join(directory, "home.sqlite"))

    assert {:ok, %{firmware: %{validation_status: :unvalidated}, home: home}} =
             BoardSnapshot.capture(GoodRuntime, store, fn -> {:ok, %{filesystem: "f2fs"}} end)

    assert home.dispatch_enabled == false
    assert home.writable == true

    assert {:ok, %{firmware: %{validation_status: :unknown}}} =
             BoardSnapshot.capture(UnknownRuntime, store, fn -> {:ok, %{filesystem: "f2fs"}} end)

    assert {:error, :unexpected_target} = BoardSnapshot.capture(WrongTarget, store)
    assert {:error, :host_unavailable} = BoardSnapshot.capture(GoodRuntime, nil)

    assert {:error, :data_mount_unavailable} =
             BoardSnapshot.capture(GoodRuntime, store, fn ->
               {:error, :data_mount_unavailable}
             end)
  end
end
