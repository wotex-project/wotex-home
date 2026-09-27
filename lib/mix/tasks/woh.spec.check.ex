defmodule Mix.Tasks.Woh.Spec.Check do
  @moduledoc "Checks the catalogue against committed spec identities, cases, and dependencies."
  @shortdoc "Check WOH spec catalogue consistency"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    directory = Path.expand("docs/specs", File.cwd!())

    case check(directory) do
      {:ok, count} ->
        Mix.shell().info(
          "#{count} spec contracts match catalogue identity, versions, cases and dependencies"
        )

      {:error, failures} ->
        Mix.raise(Enum.join(failures, "\n"))
    end
  end

  def run(_args), do: Mix.raise("usage: mix woh.spec.check")

  @doc false
  def check(spec_directory) do
    catalogue = YamlElixir.read_from_file!(Path.join(spec_directory, "catalogue.yaml"))
    contracts = Map.fetch!(catalogue, "contracts")
    external = Map.fetch!(catalogue, "external_contracts")
    ids = Enum.map(contracts, &Map.fetch!(&1, "id"))

    failures =
      if Enum.uniq(ids) == ids, do: [], else: ["duplicate contract IDs"]

    failures =
      Enum.reduce(contracts, failures, fn contract, errors ->
        check_contract(contract, spec_directory, ids, external) ++ errors
      end)

    by_id = Map.new(contracts, &{Map.fetch!(&1, "id"), &1})

    failures =
      Enum.reduce(ids, failures, fn id, errors ->
        check_cycle(id, by_id, MapSet.new(), [], errors)
      end)
      |> Enum.uniq()
      |> Enum.reverse()

    if failures == [], do: {:ok, length(contracts)}, else: {:error, failures}
  end

  defp check_contract(contract, spec_directory, ids, external) do
    id = Map.fetch!(contract, "id")
    filename = Map.fetch!(contract, "file")
    directory = Path.expand(spec_directory)
    path = Path.expand(filename, directory)

    if not String.starts_with?(path, directory <> "/") or not File.regular?(path) do
      ["#{id}: missing spec file #{filename}"]
    else
      body = File.read!(path)
      heading = body |> String.split("\n", parts: 2) |> hd()

      version =
        case Regex.run(~r/^Version: (\d+\.\d+\.\d+)\./m, body) do
          [_, value] -> value
          _ -> "missing"
        end

      cases = Map.fetch!(contract, "required_cases")
      requires = Map.fetch!(contract, "requires")

      []
      |> add_unless(
        String.starts_with?(heading, "# #{id} "),
        "#{id}: heading does not match catalogue"
      )
      |> add_unless(
        version == Map.fetch!(contract, "version"),
        "#{id}: catalogue #{contract["version"]} != file #{version}"
      )
      |> add_unless(Enum.uniq(cases) == cases, "#{id}: duplicate required cases")
      |> add_unless(
        contract["implementation_status"] in ~w(planned partial complete),
        "#{id}: unknown implementation status"
      )
      |> add_unless(
        contract["evidence_status"] in ~w(missing partial complete),
        "#{id}: unknown evidence status"
      )
      |> then(fn errors ->
        Enum.reduce(cases, errors, fn required_case, acc ->
          add_unless(
            acc,
            String.contains?(body, required_case),
            "#{id}: #{required_case} absent from spec"
          )
        end)
      end)
      |> then(fn errors ->
        Enum.reduce(requires, errors, fn dependency, acc ->
          add_unless(
            acc,
            dependency in ids or Map.has_key?(external, dependency),
            "#{id}: unknown dependency #{dependency}"
          )
        end)
      end)
    end
  end

  defp add_unless(errors, true, _message), do: errors
  defp add_unless(errors, false, message), do: [message | errors]

  defp check_cycle(id, by_id, visiting, path, errors) do
    if MapSet.member?(visiting, id) do
      ["dependency cycle: #{Enum.join(path ++ [id], " -> ")}" | errors]
    else
      visiting = MapSet.put(visiting, id)

      by_id
      |> Map.fetch!(id)
      |> Map.fetch!("requires")
      |> Enum.filter(&Map.has_key?(by_id, &1))
      |> Enum.reduce(errors, fn dependency, acc ->
        check_cycle(dependency, by_id, visiting, path ++ [id], acc)
      end)
    end
  end
end
