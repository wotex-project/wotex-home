defmodule WotexHome.HttpHeaderDependencyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  @cowlib_ref "4401b858f2229abb3ea115c60924f6c77e5f8aa3"

  test "both locks retain the reviewed patched encoder and the acknowledged client mitigation" do
    root = Mix.Dep.Lock.read("mix.lock")
    firmware = Mix.Dep.Lock.read("native/nerves/mix.lock")

    assert root[:cowlib] ==
             {:git, "https://github.com/ninenines/cowlib.git", @cowlib_ref, [ref: @cowlib_ref]}

    assert {:hex, :gun, "2.7.0", _, _, _, _, _} = root[:gun]
    assert root[:cowlib] == firmware[:cowlib]
    assert root[:gun] == firmware[:gun]
    assert root[:emqtt] == firmware[:emqtt]

    assert WotexHome.MixProject.project()[:hex] ==
             [ignore_advisories: ["GHSA-w4f7-4cxr-rv3c"]]
  end

  test "structured strings reject every non-printable byte before producing header data" do
    for byte <- Enum.to_list(0..31) ++ Enum.to_list(127..255),
        input <- [<<byte>>, <<?A, byte>>, <<byte, ?Z>>, <<?A, byte, ?Z>>] do
      assert_raise FunctionClauseError, fn -> encode(input) end
    end
  end

  test "printable strings and escaped quotes and backslashes retain their values" do
    printable = for byte <- 32..126, into: <<>>, do: <<byte>>
    assert {:item, {:string, ^printable}, []} = :cow_http_struct_hd.parse_item(encode(printable))
    assert encode(<<?A, ?", ?\\>>) == <<?", ?A, ?\\, ?", ?\\, ?\\, ?">>
  end

  test "default Gun public calls reject CR LF and NUL before casting any request" do
    for bad <- ["\r", "\n", <<0>>],
        headers <- [[{"x-probe", "before" <> bad <> "after"}], [{"x-probe" <> bad, "value"}]] do
      assert {:invalid_request_header, _, _} =
               catch_error(:gun.headers(self(), "GET", "/", headers, %{}))

      assert {:invalid_request_header, _, _} =
               catch_error(:gun.request(self(), "GET", "/", headers, "", %{}))

      refute_received {:"$gen_cast", _}
    end

    headers = [{"x-probe", "printable"}]
    sender = self()
    ref = :gun.headers(sender, "GET", "/", headers, %{})
    assert_received {:"$gen_cast", {:headers, ^sender, ^ref, "GET", "/", ^headers, :infinity}}
    refute_received {:"$gen_cast", _}
    ref = :gun.request(sender, "GET", "/", headers, "", %{})
    assert_received {:"$gen_cast", {:request, ^sender, ^ref, "GET", "/", ^headers, "", :infinity}}
    refute_received {:"$gen_cast", _}
  end

  defp encode(input),
    do: :cow_http_struct_hd.item({:item, {:string, input}, []}) |> IO.iodata_to_binary()
end
