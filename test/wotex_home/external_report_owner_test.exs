defmodule WotexHome.ExternalReportOwnerTest do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Profiles.ExternalReportOwner

  test "invalid native configuration is refused before linking or accepting custody" do
    for options <- [
          nil,
          %{},
          [],
          [:bad],
          [publisher: self()],
          [publisher: self(), source_owner: self(), store_owner: nil],
          [publisher: self(), source_owner: self(), store_owner: self(), ttl_ms: 0],
          [publisher: self(), source_owner: self(), store_owner: self(), name: 123],
          [publisher: self(), source_owner: self(), store_owner: self(), report_limit: 257],
          [publisher: self(), source_owner: self(), store_owner: self(), max_bytes: 4_194_305],
          [publisher: self(), source_owner: self(), store_owner: self(), unknown: true],
          [publisher: self(), publisher: self(), source_owner: self(), store_owner: self()]
        ] do
      assert {:error, :invalid_external_report_owner} = ExternalReportOwner.start_link(options)
    end

    assert ExternalReportOwner.child_spec([]).restart == :temporary
  end

  test "OTP status formatting redacts the private state and incoming message" do
    assert %{state: :private_external_report_owner, message: :redacted} =
             ExternalReportOwner.format_status(%{
               state: %{report: "private"},
               message: {"private", self()}
             })
  end
end
