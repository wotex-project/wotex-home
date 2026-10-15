defmodule WotexHome.ExternalReportLifetimeFixture do
  @moduledoc false

  alias WotexHome.Profiles.{ExternalSourceSelection, ReaderSelection}

  def read(name), do: JSON.decode!(File.read!("test/fixtures/profiles/" <> name <> ".json"))

  def selection(family, changes \\ %{}) do
    inputs = read("external-source-selections")[family]["inputs"]
    r = inputs["reader"]
    {:ok, reader} = ReaderSelection.new(r["installed"], r["capture"], r["reader_limits"])

    {:ok, selection} =
      ExternalSourceSelection.new(
        Map.merge(inputs["source"], changes),
        reader,
        inputs["channels"]
      )

    selection
  end
end
