alias WotexHome.Durable.Store
alias WotexHome.Semantics.Thing

[data_dir, credential_file] = System.argv()
File.mkdir!(data_dir)
File.chmod!(data_dir, 0o700)
{:ok, store} = Store.start_link(path: Path.join(data_dir, "home.sqlite"))

{:ok, thing} =
  Thing.new(%{
    "id" => "light:parity",
    "role" => "Light",
    "profile_ref" => "lifx.fixture:1",
    "capabilities" => [
      %{
        "thing_id" => "light:parity",
        "role" => "Light",
        "key" => "power",
        "value_kind" => "boolean",
        "unit" => "none",
        "operations" => ["read", "write"],
        "risk_class" => "ordinary",
        "profile_ref" => "lifx.fixture:1",
        "evidence_ref" => "fixture:parity",
        "freshness_ms" => 5_000,
        "constraints" => %{},
        "extensions" => %{}
      }
    ]
  })

{:ok, 1} = Store.enroll_thing(store, thing)

{:ok, credential, 2} =
  Store.provision_principal(
    store,
    "operator:parity",
    [
      "control:ordinary",
      "rule:review",
      "rule:manage",
      "host:maintain",
      "profile:manage",
      "enroll:review"
    ],
    [thing.id]
  )

File.write!(credential_file, Base.url_encode64(credential, padding: false))
File.chmod!(credential_file, 0o600)
:ok = GenServer.stop(store)
