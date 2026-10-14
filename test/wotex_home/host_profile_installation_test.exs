defmodule WotexHome.HostProfileInstallationTest do
  use ExUnit.Case, async: false
  alias WotexHome.{Authority, Host}
  alias WotexHome.Durable.Store

  alias WotexHome.Profiles.{
    AuthoringObject,
    ExternalReportOwner,
    ExternalSourceOwner,
    ExternalSourceSelection
  }

  defp fixture(name), do: JSON.decode!(File.read!("test/fixtures/profiles/#{name}.json"))

  setup do
    directory =
      Path.join(System.tmp_dir!(), "home-profile-host-#{System.unique_integer([:positive])}")

    publisher = spawn(fn -> publisher_loop() end)

    on_exit(fn ->
      Process.exit(publisher, :kill)
      File.rm_rf!(directory)
    end)

    v = fixture("temperature")

    config = %{
      installed: Map.take(v, ~w(bindings contracts home_contracts)),
      capture: v["capture"],
      reader_limits: v["reader_limits"],
      authoring_limits: fixture("authoring-mechanics")["temperature"]["limits"],
      publisher: publisher
    }

    {:ok, directory: directory, publisher: publisher, config: config}
  end

  defp publisher_loop do
    receive do
      {caller, ref, callback} ->
        send(caller, {ref, callback.()})
        publisher_loop()
    end
  end

  defp publish(publisher, callback) do
    ref = make_ref()
    send(publisher, {self(), ref, callback})

    receive do
      {^ref, result} -> result
    after
      5000 -> flunk("publisher did not reply")
    end
  end

  @tag requires_socket: true
  test "explicit host supplies actual Store authoring basis and empty guarded custody", context do
    %{directory: directory, publisher: publisher, config: config} = context
    {:ok, prepared} = WotexHome.Host.ProfileInstallation.prepare(config)
    assert {:ok, host} = Host.start_link(data_dir: directory, profile_installation: config)
    Process.unlink(host)
    on_exit(fn -> if Process.alive?(host), do: Supervisor.stop(host) end)
    store = Host.store()
    source = Host.external_sources()
    reports = Host.external_reports()
    assert is_pid(source) and is_pid(reports)
    assert {:ok, %{"sources" => []}} = ExternalSourceOwner.catalogue(source)
    assert {:ok, %{"receipts" => []}} = ExternalReportOwner.catalogue(reports)
    assert {:error, :external_source_publisher_denied} = ExternalSourceOwner.publish(source, %{})
    assert {:ok, %{dispatch_enabled: false}} = Store.health(store)
    assert Process.whereis(WotexHome.Host.ScheduleDelivery) == nil

    {:ok, credential, 1} =
      Store.provision_principal(store, "author:installed", ["profile:manage"], [])

    draft_bytes = fixture("authoring-mechanics")["temperature"]["draft_bytes"]
    {:ok, object} = AuthoringObject.new("draft", draft_bytes)
    {:ok, summary} = AuthoringObject.summary(object)

    assert {:ok, _} =
             Store.import_authoring_object(
               store,
               credential,
               %{
                 "authority_epoch" => 1,
                 "operation_id" => "import:installed",
                 "expected_revision" => 1,
                 "object" => summary
               },
               draft_bytes
             )

    {:ok, basis} = WotexHome.Profiles.AuthoringContract.to_map(prepared.authoring)

    input =
      fixture("authoring-candidate")["input"]
      |> Map.put("expected_revision", 2)
      |> put_in(["request", "contract_digest"], basis["contract_sha256"])
      |> put_in(["request", "limits"], basis["limits"])
      |> put_in(["request", "base_draft_ref"], %{
        "object_digest" => summary["object_digest"],
        "first_revision" => 2
      })

    assert {:ok, receipt} =
             Authority.assess_authoring_candidate(Host.authority(), credential, input)

    assert receipt["disposition"] == "compatible"

    assert {:ok, ^receipt} =
             Store.authoring_candidate_status(store, credential, 1, input["operation_id"])

    source_input = fixture("external-source-selections")["temperature"]["inputs"]

    {:ok, selection} =
      ExternalSourceSelection.new(
        source_input["source"],
        prepared.reader,
        source_input["channels"]
      )

    assert {:ok, _} = publish(publisher, fn -> ExternalSourceOwner.publish(source, selection) end)
    assert {:ok, %{"sources" => [_]}} = ExternalSourceOwner.catalogue(source)
    {:ok, receipt_clock} = ExternalReportOwner.receipt_clock(reports)

    report =
      hd(fixture("authoring-fixtures")["temperature"]["fixtures"])["report"]
      |> Map.put("source_ref", source_input["source"]["source_ref"])
      |> Map.put("receipt_time", receipt_clock)

    assert {:ok, transport_receipt} =
             publish(publisher, fn ->
               ExternalReportOwner.publish(
                 reports,
                 "report:installed",
                 source_input["source"]["source_ref"],
                 selection.sha256,
                 report
               )
             end)

    assert transport_receipt["state"] == "pending"

    assert {:error, :external_report_store_denied} =
             ExternalReportOwner.checkout(reports, "report:installed")

    assert {:ok, first_sources} = ExternalSourceOwner.catalogue(source)
    assert {:ok, first_reports} = ExternalReportOwner.catalogue(reports)
    first_monitor = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^first_monitor, :process, ^store, :killed}, 5000

    assert eventually(fn ->
             is_pid(Host.store()) and Host.store() != store and is_pid(Host.external_reports()) and
               Host.external_reports() != reports
           end)

    assert {:ok, %{"sources" => [], "owner_epoch" => new_source_epoch}} =
             ExternalSourceOwner.catalogue(Host.external_sources())

    assert {:ok, %{"receipts" => [], "owner_epoch" => new_report_epoch}} =
             ExternalReportOwner.catalogue(Host.external_reports())

    refute new_source_epoch == first_sources["owner_epoch"]
    refute new_report_epoch == first_reports["owner_epoch"]

    assert {:ok, ^receipt} =
             Store.authoring_candidate_status(Host.store(), credential, 1, input["operation_id"])

    assert {:ok, 3} = Store.revision(Host.store())

    new_source = Host.external_sources()
    new_reports = Host.external_reports()
    source_monitor = Process.monitor(new_source)
    report_monitor = Process.monitor(new_reports)
    Process.exit(publisher, :kill)
    assert_receive {:DOWN, ^source_monitor, :process, ^new_source, _}, 5000
    assert_receive {:DOWN, ^report_monitor, :process, ^new_reports, _}, 5000
    assert Host.external_sources() == nil
    assert Host.external_reports() == nil
    assert {:ok, 3} = Store.revision(Host.store())
  end

  defp eventually(callback, attempts \\ 500)
  defp eventually(_, 0), do: false

  defp eventually(callback, attempts) do
    if callback.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(callback, attempts - 1)
        )
  end
end
