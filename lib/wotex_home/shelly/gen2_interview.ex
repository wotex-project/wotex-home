defmodule WotexHome.Shelly.Gen2Interview do
  @moduledoc """
  Reads one Shelly identity and one switch status from the same local endpoint.

  Name the live LAN interface, numeric IPv4 peer and switch component before
  calling `run/4`. The interview selects the interface before each HTTP read
  and stops if its address or prefix changes. It then requires the status
  response to name the same device as the identity response. The result is a
  report for an operator to review, not an enrolled Thing or a Home observation.

  `run_scoped/5` accepts a selected scope and a scope checker for independent
  transport fixtures. A production caller should use `run/4` so interface
  changes are checked against the operating system on each exchange.
  """

  alias WotexHome.Lifx.InterfaceSelection
  alias WotexHome.Lifx.IPv4Scope
  alias WotexHome.Shelly.Gen2ReadPath

  @type report :: %{
          device_id: String.t(),
          model: String.t(),
          generation: 2 | 3 | 4,
          firmware_id: String.t(),
          firmware_version: String.t(),
          authentication_enabled: boolean(),
          switch_id: non_neg_integer(),
          output: boolean(),
          trust: :unauthenticated_local
        }

  @doc "Interviews one selected peer after selecting and rechecking the named interface."
  @spec run(String.t(), tuple(), pos_integer(), non_neg_integer()) ::
          {:ok, report()} | {:error, atom()}
  def run(interface_name, address, port, switch_id) do
    with {:ok, scope} <- InterfaceSelection.select(interface_name) do
      run_scoped(scope, address, port, switch_id, fn ->
        InterfaceSelection.select(interface_name)
      end)
    end
  end

  @doc "Runs the same interview with an explicit scope checker for a transport fixture."
  @spec run_scoped(IPv4Scope.t(), tuple(), pos_integer(), non_neg_integer(), (-> term())) ::
          {:ok, report()} | {:error, atom()}
  def run_scoped(%IPv4Scope{} = scope, address, port, switch_id, check_scope)
      when is_function(check_scope, 0) do
    with :ok <- current_scope(scope, check_scope),
         {:ok, identity} <- Gen2ReadPath.run(scope, address, port, :device_info, 1),
         :ok <- current_scope(scope, check_scope),
         {:ok, status} <-
           Gen2ReadPath.run(scope, address, port, {:switch_status, switch_id}, 2),
         :ok <- current_scope(scope, check_scope),
         true <- identity.device_id == status.device_id do
      {:ok,
       identity
       |> Map.take([
         :device_id,
         :model,
         :generation,
         :firmware_id,
         :firmware_version,
         :authentication_enabled,
         :trust
       ])
       |> Map.merge(%{switch_id: status.switch_id, output: status.output})}
    else
      false -> {:error, :device_identity_changed}
      {:error, _} = error -> error
    end
  end

  def run_scoped(_, _, _, _, _), do: {:error, :invalid_read_target}

  defp current_scope(scope, check_scope) do
    case check_scope.() do
      {:ok, ^scope} -> :ok
      _ -> {:error, :selected_interface_changed}
    end
  end
end
