ExUnit.start(autorun: false)
Code.require_file("external_input_store_fixture.exs", __DIR__)
Code.require_file("external_input_review_fixture.exs", __DIR__)

defmodule WotexHome.ExternalInputContextRuntimeProbe do
  @moduledoc false

  use ExUnit.Case
  alias WotexHome.Authority
  alias WotexHome.ExternalInputStoreFixture, as: F
  alias WotexHome.ExternalInputReviewFixture, as: R
  alias WotexHome.Durable.Store.SQL
  @applications [:wotex_home, :wotex, :gun, :telemetry]

  setup_all do
    root = System.fetch_env!("WOH_INPUT_CONTEXT_RUNTIME_ROOT")

    copies =
      Map.new(@applications, fn app ->
        original =
          :code.get_path()
          |> Enum.find(fn path ->
            File.regular?(Path.join(List.to_string(path), Atom.to_string(app) <> ".app"))
          end)
          |> List.to_string()

        private = Path.join(root, Atom.to_string(app))
        File.mkdir!(private)

        for path <- Path.wildcard(Path.join(original, "*")),
            File.regular?(path),
            do: File.cp!(path, Path.join(private, Path.basename(path)))

        priv = Path.join(Path.dirname(original), "priv")
        if File.dir?(priv), do: File.ln_s!(priv, Path.join(private, "priv"))
        true = :code.del_path(String.to_charlist(original))
        true = :code.add_patha(String.to_charlist(private))
        {app, private}
      end)

    {:ok, _} = Application.ensure_all_started(:wotex_home)
    %{copies: copies}
  end

  setup do
    F.setup()
  end

  for app <- @applications do
    @application app
    test "actual Store closing rejects changed complete bytes in #{app}", c do
      c = F.prepare(c)
      [module | _] = Application.spec(@application, :modules)
      path = Path.join(c.copies[@application], Atom.to_string(module) <> ".beam")
      bytes = File.read!(path)
      {:ok, ^module, chunks} = :beam_lib.all_chunks(bytes)

      {:ok, changed} =
        :beam_lib.build_module(chunks ++ [{~c"TEST", "changed during context preparation"}])

      {:ok, {^module, checksum}} = :beam_lib.md5(bytes)
      {:ok, {^module, ^checksum}} = :beam_lib.md5(changed)

      custody = c.custody
      :ok = :sys.suspend(custody)
      :erlang.trace(custody, true, [:receive])

      task =
        Task.async(fn ->
          Authority.external_routine_input_context(
            c.authority,
            c.credential,
            "sensor:external",
            "sample"
          )
        end)

      try do
        assert_receive {:trace, ^custody, :receive, {:"$gen_call", _, {:read_object, _}}}, 3000
        File.write!(path, changed)
        :ok = :sys.resume(custody)
        assert {:error, :runtime_artifact_unavailable} = Task.await(task, 5000)
      after
        File.write!(path, bytes)
        :erlang.trace(custody, false, [:receive])
        :sys.resume(custody)
      end

      assert :sys.get_state(c.store).writable

      assert {:ok, _} =
               Authority.external_routine_input_context(
                 c.authority,
                 c.credential,
                 "sensor:external",
                 "sample"
               )
    end
  end

  for app <- @applications do
    @application app
    test "complete collector scope rejects closing artifact drift in #{app}", c do
      keys = R.keys()

      c =
        F.prepare(Map.merge(c, keys),
          case_keys: keys.case_keys,
          decision_keys: keys.decision_keys
        )

      review = R.review(c, "runtime-collector")

      assert {:ok, _} =
               Authority.change_external_routine_input(
                 c.authority,
                 c.credential,
                 R.install(review)
               )

      [module | _] = Application.spec(@application, :modules)
      path = Path.join(c.copies[@application], Atom.to_string(module) <> ".beam")
      bytes = File.read!(path)
      {:ok, ^module, chunks} = :beam_lib.all_chunks(bytes)

      {:ok, changed} =
        :beam_lib.build_module(chunks ++ [{~c"TEST", "changed during scope collection"}])

      {:ok, {^module, checksum}} = :beam_lib.md5(bytes)
      {:ok, {^module, ^checksum}} = :beam_lib.md5(changed)

      scope =
        Enum.map(1..31, fn n ->
          %{
            "target_id" => "sensor:external",
            "capability_key" => "missing:" <> String.pad_leading(Integer.to_string(n), 2, "0")
          }
        end) ++ [%{"target_id" => "sensor:external", "capability_key" => "sample"}]

      before = retained(c)
      custody = c.custody
      :ok = :sys.suspend(custody)
      :erlang.trace(custody, true, [:receive])

      task =
        Task.async(fn -> Authority.external_routine_facts(c.authority, c.credential, scope) end)

      try do
        assert_receive {:trace, ^custody, :receive, {:"$gen_call", _, {:read_object, _}}}, 3000
        File.write!(path, changed)
        :ok = :sys.resume(custody)
        assert {:error, :external_input_basis_changed} = Task.await(task, 5000)
      after
        File.write!(path, bytes)
        :erlang.trace(custody, false, [:receive])
        :sys.resume(custody)
      end

      assert retained(c) == before
      assert :sys.get_state(c.store).writable
      assert {:ok, snapshot} = Authority.external_routine_facts(c.authority, c.credential, scope)
      assert length(snapshot["items"]) == 32
      assert List.last(snapshot["items"])["reason"] == "missing_report"
      assert List.last(snapshot["items"])["binding_basis"] != nil
      assert retained(c) == before
    end
  end

  defp retained(c) do
    for table <-
          ~w(meta routine_external_input_operations routine_external_input_history routine_external_input_current authority_journal),
        into: %{} do
      {:ok, rows} =
        SQL.query(:sys.get_state(c.store).db, "SELECT * FROM " <> table <> " ORDER BY rowid")

      {table, rows}
    end
  end
end

case ExUnit.run() do
  %{failures: 0} -> :ok
  _ -> System.halt(1)
end
