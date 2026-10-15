defmodule WotexHome.Rules.ExternalInputOperation do
  @moduledoc """
  Encodes immutable external-input changes, outcomes and original receipts.

  Use `encode/1` and `decode/1` for install/revoke changes,
  `encode_outcome/1` and `decode_outcome/1` for retained outcomes, and
  `encode_receipt/1` and `decode_receipt/1` for scoped user receipts. Encoders
  accept closed string-key maps and return `{:ok, document}`; decoders require
  exact canonical ordered wire and return `{:ok, data}`. Every refusal returns
  `{:error, reason}` with a closed external-input code.

  Install changes retain a complete `WotexHome.Rules.ExternalInputPackage`
  matching their target, capability key and authority epoch. Revoke changes have
  a null package and positive expected installation revision and generation;
  a missing slot's install expectations are exactly zero/zero. Outcomes retain
  the reviewed package and its Definition hash, including for revoke/withdraw.
  Change and outcome documents are each bounded to 524,288 bytes, embedded
  packages to 262,144 bytes and receipts to 4096 bytes.

  `validate_original/3` takes the exact input, outcome and receipt documents and
  returns `{:ok, original}` with exactly the string keys `"input"`, `"outcome"`
  and `"receipt"`, or `{:error, reason}`. It repeats decoding and checks scope,
  action, format-separated input/outcome hashes, generation advancement and
  installation revision correspondence. Install also requires the exact input
  package, its original Store boot witness and preceding selection/binding/trust
  revisions. These are immutable correspondence checks, not current-state reads.

  All codecs and the original join are independent of producers, reviewer keys,
  current programme files and live sources. Revoke can retain an older
  installation revision under a new Store boot or authority epoch without
  requalifying it. Withdraw has an outcome but no scoped user-operation receipt.

  Store owns actor authentication, current revision/generation comparisons,
  principal ownership, journal/history/current row links and SQLite transactions.
  A valid historical original neither installs nor reactivates an input and
  establishes no current authorization or physical qualification.
  """

  alias WotexHome.Profiles.{AuthoringWire, DocumentChunks}
  alias WotexHome.Rules.{ExternalInput, ExternalInputFormat, ExternalInputPackage}

  @input_tag "wotex-home.external-input.v1"
  @outcome_tag "wotex-home.external-input-result.v1"
  @receipt_tag "wotex-home.external-input-receipt.v1"
  @input ~w(authority_epoch operation_id target_id capability_key expected_install_revision expected_generation action package_document)
  @outcome ~w(action target_id capability_key definition_sha256 package_document)
  @receipt ~w(authority_epoch operation_id target_id capability_key revision generation install_revision action input_sha256 outcome_sha256 store_boot_epoch)
  @outcome_format "wotex-home.external-input-result@1"
  @receipt_format "wotex-home.external-input-receipt@1"

  @doc "Encodes a scoped install/revoke original without current authorization or qualification."
  @spec encode(term()) :: {:ok, String.t()} | {:error, atom()}
  def encode(input) do
    ExternalInputFormat.guard(
      fn ->
        with :ok <- header(input, "input_change"),
             :ok <- expected(input),
             {:ok, package} <- input_package(input),
             values = Enum.map(@input, &input[&1]) |> List.replace_at(7, package),
             do: ExternalInputFormat.wire([@input_tag | values], 524_288),
             else: (
               {:error, _} = error -> error
               _ -> invalid()
             )
      end,
      :document
    )
  end

  @doc "Decodes one exact canonical scoped original independently of installed producer availability."
  @spec decode(term()) :: {:ok, map()} | {:error, atom()}
  def decode(document) do
    ExternalInputFormat.guard(fn ->
      with {:ok, [@input_tag | values]} <- AuthoringWire.decode(document, 524_288),
           true <- length(values) == 8,
           {:ok, package} <- input_document(Enum.at(values, 7)),
           data = Map.new(Enum.zip(@input, List.replace_at(values, 7, package))),
           {:ok, ^document} <- encode(data),
           do: {:ok, data},
           else: (
             {:error, _} = error -> error
             _ -> invalid()
           )
    end)
  end

  @doc "Encodes an install/revoke/withdraw outcome retaining its exact last reviewed package."
  @spec encode_outcome(term()) :: {:ok, String.t()} | {:error, atom()}
  def encode_outcome(data) do
    ExternalInputFormat.guard(
      fn ->
        with :ok <- header(data, "input_outcome"),
             {:ok, definition} <- package_definition(data["package_document"]),
             true <-
               slot?(data, definition["data"]["context"]) and
                 data["definition_sha256"] == definition["sha256"],
             {:ok, package} <- DocumentChunks.encode(data["package_document"], 262_144),
             values = Enum.map(@outcome, &data[&1]) |> List.replace_at(4, package),
             do: ExternalInputFormat.wire([@outcome_tag | values], 524_288),
             else: (
               {:error, _} = error -> error
               _ -> invalid()
             )
      end,
      :document
    )
  end

  @doc "Decodes and checks exact historical outcome/package correspondence."
  @spec decode_outcome(term()) :: {:ok, map()} | {:error, atom()}
  def decode_outcome(document) do
    ExternalInputFormat.guard(fn ->
      with {:ok, [@outcome_tag | values]} <- AuthoringWire.decode(document, 524_288),
           true <- length(values) == 5,
           {:ok, package} <- DocumentChunks.decode(Enum.at(values, 4), 262_144),
           data =
             Map.new(Enum.zip(@outcome, List.replace_at(values, 4, package)))
             |> Map.put("format", @outcome_format),
           {:ok, ^document} <- encode_outcome(data),
           do: {:ok, data},
           else: (
             {:error, _} = error -> error
             _ -> invalid()
           )
    end)
  end

  @doc "Encodes the closed scoped user receipt; withdrawal is retained only in history."
  @spec encode_receipt(term()) :: {:ok, String.t()} | {:error, atom()}
  def encode_receipt(data) do
    ExternalInputFormat.guard(
      fn ->
        with :ok <- ExternalInputFormat.bounded(data),
             true <- ExternalInputFormat.shape?(data, "input_receipt"),
             true <-
               (data["action"] == "install" and data["install_revision"] == data["revision"]) or
                 (data["action"] == "revoke" and data["install_revision"] < data["revision"] and
                    data["generation"] > 1),
             do: ExternalInputFormat.wire([@receipt_tag | Enum.map(@receipt, &data[&1])], 4096),
             else: (
               {:error, _} = error -> error
               _ -> invalid()
             )
      end,
      :document
    )
  end

  @doc "Decodes the exact retained receipt independently of current clocks or runtime."
  @spec decode_receipt(term()) :: {:ok, map()} | {:error, atom()}
  def decode_receipt(document) do
    ExternalInputFormat.guard(fn ->
      with {:ok, [@receipt_tag | values]} <- AuthoringWire.decode(document, 4096),
           true <- length(values) == 11,
           data = Map.new(Enum.zip(@receipt, values)) |> Map.put("format", @receipt_format),
           {:ok, ^document} <- encode_receipt(data),
           do: {:ok, data},
           else: (
             {:error, _} = error -> error
             _ -> invalid()
           )
    end)
  end

  @doc "Checks the complete immutable original without querying principal, journal or current SQLite rows."
  @spec validate_original(term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def validate_original(input_document, outcome_document, receipt_document) do
    ExternalInputFormat.guard(fn ->
      with {:ok, input} <- decode(input_document),
           {:ok, outcome} <- decode_outcome(outcome_document),
           {:ok, receipt} <- decode_receipt(receipt_document),
           true <-
             Enum.all?(
               ~w(authority_epoch operation_id target_id capability_key action),
               &(input[&1] == receipt[&1])
             ),
           true <- Enum.all?(~w(target_id capability_key action), &(input[&1] == outcome[&1])),
           true <-
             receipt["input_sha256"] == input_sha256(input_document) and
               receipt["outcome_sha256"] == outcome_sha256(outcome_document),
           true <- receipt["generation"] == input["expected_generation"] + 1,
           true <- input["expected_install_revision"] < receipt["revision"],
           :ok <- original_action(input, outcome, receipt) do
        {:ok, %{"input" => input, "outcome" => outcome, "receipt" => receipt}}
      else
        {:error, _} = error -> error
        _ -> invalid()
      end
    end)
  end

  @doc false
  def input_sha256(document), do: ExternalInputFormat.hash(@input_tag, document)

  @doc false
  def outcome_sha256(document), do: ExternalInputFormat.hash(@outcome_tag, document)

  defp header(data, fragment) when is_map(data) do
    with :ok <- ExternalInputFormat.bounded(Map.delete(data, "package_document")),
         true <- ExternalInputFormat.shape?(data, fragment),
         do: :ok,
         else: (
           {:error, _} = error -> error
           _ -> invalid()
         )
  end

  defp header(_, _), do: invalid()

  defp expected(i) do
    case {i["expected_install_revision"], i["expected_generation"], i["action"]} do
      {0, 0, "install"} -> :ok
      {revision, generation, _} when revision > 0 and generation > 0 -> :ok
      _ -> invalid()
    end
  end

  defp input_package(%{"action" => "revoke", "package_document" => nil}), do: {:ok, nil}

  defp input_package(%{"action" => "install"} = i) do
    with {:ok, definition} <- package_definition(i["package_document"]),
         context = definition["data"]["context"],
         true <- slot?(i, context) and i["authority_epoch"] == context["authority_epoch"],
         do: DocumentChunks.encode(i["package_document"], 262_144),
         else: (
           {:error, _} = error -> error
           _ -> invalid()
         )
  end

  defp input_package(_), do: invalid()
  defp input_document(nil), do: {:ok, nil}
  defp input_document(chunks), do: DocumentChunks.decode(chunks, 262_144)

  defp package_definition(document) do
    with {:ok, package} <- ExternalInputPackage.decode(document),
         do: ExternalInput.decode(package["data"]["definition_document"])
  end

  defp slot?(data, context),
    do: Enum.all?(~w(target_id capability_key), &(data[&1] == context[&1]))

  defp original_action(%{"action" => "install"} = input, outcome, receipt) do
    with true <- input["package_document"] == outcome["package_document"],
         {:ok, definition} <- package_definition(outcome["package_document"]),
         context = definition["data"]["context"],
         true <- receipt["store_boot_epoch"] == context["store_boot_epoch"],
         true <-
           Enum.all?(
             ~w(selection_revision binding_revision trust_revision),
             &(context[&1] < receipt["revision"])
           ),
         do: :ok,
         else: (
           {:error, _} = error -> error
           _ -> invalid()
         )
  end

  defp original_action(%{"action" => "revoke"} = input, _outcome, receipt),
    do:
      if(receipt["install_revision"] == input["expected_install_revision"],
        do: :ok,
        else: invalid()
      )

  defp invalid, do: {:error, :invalid_external_input}
end
