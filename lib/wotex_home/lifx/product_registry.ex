defmodule WotexHome.Lifx.ProductRegistry do
  @moduledoc """
  Bounded interpretation of a caller-pinned LIFX product registry artifact.

  This reads packaged JSON only. It performs no network fetch. A resolved
  feature is vendor metadata, not device qualification or command authority.
  """

  @max_bytes 1_048_576
  @max_u32 4_294_967_295
  @pinned_digest "09f6b87367ea3a974cd4be9e7a562db73e1776d012854fb487b00ac9be520360"
  @feature_keys ~w(hev color chain matrix relays buttons infrared multizone temperature_range extended_multizone)

  @enforce_keys [:digest, :vendors]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @doc "Load only the selected local artifact, bounded and verified before use."
  @spec load_pinned(String.t()) :: {:ok, t()} | {:error, atom()}
  def load_pinned(path \\ Application.app_dir(:wotex_home, "priv/lifx/products.json"))

  def load_pinned(path) when is_binary(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.size > 0 and stat.size <= @max_bytes,
         {:ok, file} <- File.open(path, [:read, :binary]) do
      bytes =
        try do
          IO.binread(file, @max_bytes + 1)
        after
          File.close(file)
        end

      new(bytes, @pinned_digest)
    else
      _ -> {:error, :registry_unavailable}
    end
  end

  def load_pinned(_path), do: {:error, :registry_unavailable}

  @spec new(binary(), String.t()) :: {:ok, t()} | {:error, atom()}
  def new(bytes, expected_digest)
      when is_binary(bytes) and byte_size(bytes) <= @max_bytes and is_binary(expected_digest) do
    actual_digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    with true <- byte_size(expected_digest) == 64 and expected_digest == actual_digest,
         {:ok, data} <- strict_json(bytes),
         {:ok, vendors} <- validate_vendors(data) do
      {:ok, %__MODULE__{digest: actual_digest, vendors: vendors}}
    else
      false -> {:error, :registry_digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(_bytes, _digest), do: {:error, :invalid_registry}

  @spec lookup(t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom()}
  def lookup(%__MODULE__{} = registry, vendor_id, product_id, major, minor) do
    with true <- valid_u32?(vendor_id) and valid_u32?(product_id),
         true <- valid_u16?(major) and valid_u16?(minor),
         {:ok, vendor} <- Map.fetch(registry.vendors, vendor_id),
         {:ok, product} <- Map.fetch(vendor.products, product_id) do
      features =
        Enum.reduce(product.upgrades, Map.merge(vendor.defaults, product.features), fn upgrade,
                                                                                       acc ->
          if {major, minor} >= {upgrade.major, upgrade.minor},
            do: Map.merge(acc, upgrade.features),
            else: acc
        end)

      {:ok,
       %{
         vendor_id: vendor_id,
         product_id: product_id,
         firmware: {major, minor},
         vendor_name: vendor.name,
         product_name: product.name,
         features: features,
         registry_digest: registry.digest
       }}
    else
      false -> {:error, :invalid_product_identity}
      :error -> {:error, :unknown_product}
    end
  end

  defp strict_json(bytes) do
    try do
      case JSON.decode(bytes, :ok,
             object_finish: fn pairs, old_acc ->
               keys = Enum.map(pairs, &elem(&1, 0))
               if length(keys) != length(Enum.uniq(keys)), do: throw(:duplicate_member)
               {Map.new(pairs), old_acc}
             end
           ) do
        {data, :ok, ""} -> {:ok, data}
        _ -> {:error, :invalid_registry}
      end
    catch
      :throw, :duplicate_member -> {:error, :invalid_registry}
    end
  end

  defp validate_vendors(vendors)
       when is_list(vendors) and length(vendors) > 0 and length(vendors) <= 32 do
    Enum.reduce_while(vendors, {:ok, %{}, 0}, fn vendor, {:ok, acc, count} ->
      case validate_vendor(vendor) do
        {:ok, vid, value, product_count}
        when not is_map_key(acc, vid) and count + product_count <= 1_024 ->
          {:cont, {:ok, Map.put(acc, vid, value), count + product_count}}

        _ ->
          {:halt, {:error, :invalid_registry}}
      end
    end)
    |> case do
      {:ok, vendors, _count} -> {:ok, vendors}
      error -> error
    end
  end

  defp validate_vendors(_vendors), do: {:error, :invalid_registry}

  defp validate_vendor(
         %{"vid" => vid, "name" => name, "defaults" => defaults, "products" => products} = vendor
       )
       when map_size(vendor) == 4 and is_list(products) and length(products) > 0 and
              length(products) <= 1_024 do
    with true <- valid_u32?(vid) and valid_name?(name),
         :ok <- valid_features(defaults, true),
         {:ok, product_map} <- validate_products(products) do
      {:ok, vid, %{name: name, defaults: defaults, products: product_map}, map_size(product_map)}
    else
      _ -> {:error, :invalid_registry}
    end
  end

  defp validate_vendor(_vendor), do: {:error, :invalid_registry}

  defp validate_products(products) do
    Enum.reduce_while(products, {:ok, %{}}, fn product, {:ok, acc} ->
      case validate_product(product) do
        {:ok, pid, value} when not is_map_key(acc, pid) ->
          {:cont, {:ok, Map.put(acc, pid, value)}}

        _ ->
          {:halt, {:error, :invalid_registry}}
      end
    end)
  end

  defp validate_product(
         %{"pid" => pid, "name" => name, "features" => features, "upgrades" => upgrades} = product
       )
       when map_size(product) == 4 and is_list(upgrades) and length(upgrades) <= 32 do
    with true <- valid_u32?(pid) and valid_name?(name),
         :ok <- valid_features(features, false),
         {:ok, parsed_upgrades} <- validate_upgrades(upgrades) do
      {:ok, pid, %{name: name, features: features, upgrades: parsed_upgrades}}
    else
      _ -> {:error, :invalid_registry}
    end
  end

  defp validate_product(_product), do: {:error, :invalid_registry}

  defp validate_upgrades(upgrades) do
    Enum.reduce_while(upgrades, {:ok, %{}}, fn
      %{"major" => major, "minor" => minor, "features" => features} = upgrade, {:ok, acc}
      when map_size(upgrade) == 3 ->
        if valid_u16?(major) and valid_u16?(minor) and
             valid_features(features, false) == :ok and not Map.has_key?(acc, {major, minor}) do
          {:cont,
           {:ok, Map.put(acc, {major, minor}, %{major: major, minor: minor, features: features})}}
        else
          {:halt, {:error, :invalid_registry}}
        end

      _, _ ->
        {:halt, {:error, :invalid_registry}}
    end)
    |> case do
      {:ok, versions} -> {:ok, versions |> Map.values() |> Enum.sort_by(&{&1.major, &1.minor})}
      error -> error
    end
  end

  defp valid_features(features, full?) when is_map(features) and map_size(features) <= 10 do
    keys = Map.keys(features)

    if Enum.all?(keys, &(&1 in @feature_keys)) and
         (not full? or Enum.sort(keys) == Enum.sort(@feature_keys)) and
         Enum.all?(features, fn
           {"temperature_range", nil} ->
             true

           {"temperature_range", [minimum, maximum]} ->
             is_integer(minimum) and is_integer(maximum) and minimum > 0 and
               minimum <= maximum and maximum <= 65_535

           {_key, value} ->
             is_boolean(value)
         end),
       do: :ok,
       else: {:error, :invalid_registry}
  end

  defp valid_features(_features, _full?), do: {:error, :invalid_registry}

  defp valid_u32?(value), do: is_integer(value) and value >= 0 and value <= @max_u32
  defp valid_u16?(value), do: is_integer(value) and value >= 0 and value <= 65_535

  defp valid_name?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..128
end
