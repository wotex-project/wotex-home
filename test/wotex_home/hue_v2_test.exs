defmodule WotexHome.HueV2Test do
  use ExUnit.Case, async: true
  alias WotexHome.Hue.V2
  @bridge "0123456789abcdef"
  @light "12345678-1234-1234-1234-123456789abc"
  @device "12345678-1234-1234-1234-123456789def"

  test "only closed read paths can be constructed" do
    assert {:ok, "/clip/v2/resource/light"} = V2.path(:lights)
    assert {:ok, "/clip/v2/resource/bridge"} = V2.path(:bridges)
    assert {:ok, path} = V2.path({:light, @light})
    assert path == "/clip/v2/resource/light/" <> @light

    for bad <- [
          :set,
          :identify,
          :powerup,
          :grouped_light,
          {:light, "../device"},
          {:light, "bad?key=secret"}
        ],
        do: assert({:error, :invalid_hue_query} = V2.path(bad))
  end

  test "bounded Light projection retains exact typed values without inventing support" do
    assert {:ok, [report]} = V2.response(body([light()]), {:light, @light}, @bridge)

    assert report == %{
             resource_id: @light,
             device_id: @device,
             power: true,
             mode: "normal",
             brightness_ppm: 211_250,
             colour_temperature_kelvin: 5_000
           }

    raw = light() |> Map.delete("dimming") |> put_in(["color_temperature", "mirek_valid"], false)

    assert {:ok, [%{brightness_ppm: nil, colour_temperature_kelvin: nil}]} =
             V2.response(body([raw]), :lights, @bridge)

    assert {:ok, []} = V2.response(body([]), :lights, @bridge)
  end

  test "identity collisions, group resources, partial errors and malformed quantities fail closed" do
    for data <- [
          [light(), light()],
          [%{light() | "type" => "grouped_light"}],
          [put_in(light(), ["dimming", "brightness"], 100.1)],
          [put_in(light(), ["on", "on"], "true")],
          [put_in(light(), ["color_temperature", "mirek"], 0)],
          [put_in(light(), ["color_temperature", "mirek_schema", "mirek_minimum"], 300)]
        ],
        do: assert({:error, :invalid_hue_response} = V2.response(body(data), :lights, @bridge))

    assert {:error, _} = V2.response(body([]), {:light, @light}, @bridge)

    assert {:error, _} =
             V2.response(
               JSON.encode!(%{"errors" => [%{"description" => "bad"}], "data" => [light()]}),
               :lights,
               @bridge
             )

    assert {:error, _} = V2.response(~s({"errors":[],"data":[],"data":[]}), :lights, @bridge)
    assert {:error, _} = V2.response(String.duplicate("[", 17), :lights, @bridge)
    assert {:error, _} = V2.response(String.duplicate("x", 262_145), :lights, @bridge)
  end

  test "bridge resource must repeat the selected bridge identity" do
    data = [%{"id" => @device, "type" => "bridge", "bridge_id" => @bridge}]
    assert {:ok, [%{bridge_id: @bridge}]} = V2.response(body(data), :bridges, @bridge)
    assert {:error, _} = V2.response(body(data), :bridges, "ffffffffffffffff")
  end

  defp body(data), do: JSON.encode!(%{"errors" => [], "data" => data})

  defp light,
    do: %{
      "id" => @light,
      "type" => "light",
      "owner" => %{"rid" => @device, "rtype" => "device"},
      "on" => %{"on" => true},
      "mode" => "normal",
      "dimming" => %{"brightness" => 21.125},
      "color_temperature" => %{
        "mirek" => 200,
        "mirek_valid" => true,
        "mirek_schema" => %{"mirek_minimum" => 153, "mirek_maximum" => 500}
      }
    }
end
