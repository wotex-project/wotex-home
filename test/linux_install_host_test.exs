defmodule WotexHome.LinuxInstallHostTest do
  use ExUnit.Case, async: true
  alias Woh.Tool.LinuxInstallHost

  test "local and NSS account occupancy cannot be adopted" do
    lookup = fn database, id ->
      send(self(), {database, id})
      {:ok, if(id == "102", do: :present, else: :absent)}
    end

    assert {:ok, 103} =
             LinuxInstallHost.choose_account_id(
               "existing:x:100:100::/:/usr/sbin/nologin\n",
               "existing:x:101:\n",
               lookup
             )

    assert_received {"passwd", "102"}
    assert_received {"group", "102"}
    assert_received {"passwd", "103"}
    assert_received {"group", "103"}
    refute_received {_, "100"}
    refute_received {_, "101"}
  end

  test "resolver failures stop before a second identity lookup" do
    lookup = fn database, id ->
      send(self(), {database, id})
      {:error, "private fixture timeout"}
    end

    assert {:error, "system account resolver unavailable"} =
             LinuxInstallHost.choose_account_id("", "", lookup)

    assert_received {"passwd", "100"}
    refute_received {_, _}
  end

  test "an occupied remote namespace has a finite query budget" do
    lookup = fn database, id ->
      send(self(), {database, id})
      {:ok, :present}
    end

    assert {:error, _} = LinuxInstallHost.choose_account_id("", "", lookup)

    for id <- 100..115, database <- ["passwd", "group"] do
      name = to_string(id)
      assert_received {^database, ^name}
    end

    refute_received {_, _}
  end
end
