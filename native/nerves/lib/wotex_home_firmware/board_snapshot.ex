defmodule WotexHome.Firmware.BoardSnapshot do
  @moduledoc """
  Read-only observations for the Raspberry Pi 4 board lab.

  This intentionally has no firmware validation or network control operation.
  A snapshot does not qualify the board, data migration, or radio.
  """

  alias WotexHome.Durable.Store
  alias WotexHome.Host

  @spec capture(module(), pid() | nil) :: {:ok, map()} | {:error, atom()}
  def capture(runtime \\ Nerves.Runtime, store \\ Host.store()) do
    with {:target, :rpi4} <- {:target, runtime.mix_target()},
         %{active: active, next: next} <- runtime.firmware_slots(),
         true <- slot?(active) and slot?(next),
         status when status in [:validated, :unvalidated, :unknown] <-
           runtime.firmware_validation_status(),
         {:store, true} <- {:store, is_pid(store)},
         {:ok, health} <- Store.health(store) do
      {:ok,
       %{
         scope: :read_only_board_lab_snapshot,
         target: :rpi4,
         firmware: %{active_slot: active, next_slot: next, validation_status: status},
         home: health,
         erlang_distribution: Node.alive?()
       }}
    else
      {:target, _} -> {:error, :unexpected_target}
      false -> {:error, :missing_board_state}
      {:store, false} -> {:error, :host_unavailable}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_board_state}
    end
  rescue
    _ -> {:error, :board_probe_unavailable}
  catch
    :exit, _ -> {:error, :board_probe_unavailable}
  end

  defp slot?(value) when is_binary(value), do: value in ["a", "b"]
  defp slot?(_), do: false
end
