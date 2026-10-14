defmodule HomeAbsentReaderSeams do
  use ExUnit.Case
  alias WotexHome.Profiles.ReaderSelection

  test "reader producer remains unavailable without its code path" do
    v =
      JSON.decode!(File.read!("test/fixtures/profiles/external-inspections.json"))["temperature"][
        "reader_inputs"
      ]

    assert {:error, :profiles_producer_unavailable} =
             ReaderSelection.new(v["installed"], v["capture"], v["reader_limits"])
  end
end
