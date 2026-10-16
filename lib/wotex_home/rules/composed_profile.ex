defmodule WotexHome.Rules.ComposedProfile do
  @moduledoc """
  Calculates inert composed routines under Home's fixed bounds.

  `WotexHome.Rules.ComposedProfile.new/0` returns `{:ok, selection}` containing
  all twelve `Wotex.Routines.Profile` and six `Wotex.Routines.Limits` selections
  for `wotex-home.composed-profile@1`. The descriptive Home identity adds no
  producer field. `WotexHome.Rules.ComposedProfile.new/2` accepts native or plain
  selections only when every value equals that fixed selection.

  Usage sketch with complete caller-supplied source, contexts and membership:

      {:ok, program} = WotexHome.Rules.ComposedProfile.compile(source, context)
      :ok = WotexHome.Rules.ComposedProfile.current(program, current_context)
      {:ok, collection} = WotexHome.Rules.ComposedProfile.collect(collection_input)
      {:ok, result} = WotexHome.Rules.ComposedProfile.arbitrate(collection, dispositions)

  `WotexHome.Rules.ComposedProfile.compile/2` accepts a complete source map,
  `Wotex.Routines.Source` or bounded JSON bytes. Its context contains exactly
  registry, bases, bindings, definitions, arguments and compiler_basis, including
  the full child-source closure and parameter values. It delegates syntax,
  typing and expansion of every possible branch and invocation copy to
  `Wotex.Routines.Compiler.compile/4`. Success is `{:ok, program}` with a
  `Wotex.Routines.Program`; refusals return `{:error, error}` containing a
  payload-free `Wotex.Routines.Error`, without a partial program or wider bounds.
  A missing required producer API refuses `:routine_kernel_unavailable`.

  `WotexHome.Rules.ComposedProfile.current/2` regenerates the whole program
  against independently supplied current context and returns `:ok` or an error.
  `WotexHome.Rules.ComposedProfile.to_map/1` instead uses the retained context
  and returns `{:ok, data}` with the complete plain program after revalidation.
  That projection establishes internal correspondence; it does not measure
  whether the retained context is still current.

  `WotexHome.Rules.ComposedProfile.collect/1` takes only an explicit
  `"wotex.routines.collection-input@2"` map with format, membership, entries
  and time. It returns `{:ok, collection}` with a `Wotex.Routines.Collection`
  containing all currently eligible proposed/reserved originals and their
  proposal states. Each live original needs an actual continuation, such as
  `"resume"`. The caller supplies membership, observations, Time and retained
  history; this calculation is no Store certificate of actual completeness.

  `WotexHome.Rules.ComposedProfile.arbitrate/2` takes a complete native/plain
  Collection@2 and explicit dispositions, revalidates the whole collection,
  and checks all constraints, overrides and resource conflicts before a fixed
  sixteen-group cutoff. It returns `{:ok, result}` with inert decisions and
  selected groups retaining every eligible equivalent contributor, including
  reserved originals. Both return `{:error, error}` with a payload-free
  `Wotex.Routines.Error` on refusal; other collection formats refuse
  `:unsupported_decision_scope`. Selection authorizes no repeated charge,
  reservation or handoff.

  Each source is limited to 32,768 bytes and depth sixteen. Expansion permits
  64 step nodes and 64 predicate nodes, four nested invokes, four branches per
  parallel node, sixteen effects and sixteen combined waits/delays. The Profile
  also selects 64 definitions, 64 active runs, 1,024 pending effects and an
  explicit run-duration ceiling of 86,400,000 elapsed milliseconds. Aggregate
  JSON limits are 64 MiB, depth 64, 2,000,000 nodes, 65,536 string bytes, 8,192
  collection members and integer magnitude 9,223,372,036,854,775,807. Every
  embedded copy counts; valid individual programs do not prove a complete
  active set fits. Existing explicit-rule selections retain their own bounds.

  These APIs neither authenticate supplied context nor install mappings,
  activate routines, reserve work or authorize physical effects.
  `WotexHome.Authority` and `WotexHome.Durable.Store` own production context,
  current membership, authorization and durable admission.
  """

  alias Wotex.Routines.{
    Arbitration,
    Codec,
    Collection,
    Compiler,
    Error,
    Limits,
    Profile,
    Program,
    Source
  }

  @profile %{
    "source_bytes" => 32_768,
    "source_depth" => 16,
    "expanded_nodes" => 64,
    "predicate_nodes" => 64,
    "invocation_depth" => 4,
    "parallel_width" => 4,
    "effects" => 16,
    "waits" => 16,
    "active_definitions" => 64,
    "active_runs" => 64,
    "pending_work" => 1024,
    "run_ms" => 86_400_000
  }
  @limits %{
    "max_bytes" => 67_108_864,
    "max_depth" => 64,
    "max_nodes" => 2_000_000,
    "max_string_bytes" => 65_536,
    "max_collection_size" => 8192,
    "max_integer" => 9_223_372_036_854_775_807
  }
  @api [
    {Profile, :new, 1},
    {Limits, :new, 1},
    {Source, :new, 3},
    {Codec, :decode_source, 3},
    {Compiler, :compile, 4},
    {Compiler, :current, 4},
    {Compiler, :to_map, 3},
    {Collection, :evaluate, 3},
    {Arbitration, :decide, 5}
  ]
  @enforce_keys [:profile, :limits]
  defstruct [:profile, :limits]
  @type t :: %__MODULE__{profile: Profile.t(), limits: Limits.t()}

  @doc "Constructs the fixed composed calculation selection."
  @spec new() :: {:ok, t()} | {:error, Error.t()}
  def new, do: new(@profile, @limits)

  @doc "Accepts only the complete exact Home Profile and Limits selections."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(profile, limits) do
    with :ok <- available(),
         {:ok, profile} <- Profile.new(profile),
         {:ok, limits} <- Limits.new(limits),
         :ok <- exact(profile.data, @profile, :invalid_profile, "/profile"),
         :ok <- exact(limits.data, @limits, :invalid_limits, "/json_limits") do
      {:ok, %__MODULE__{profile: profile, limits: limits}}
    end
  end

  @doc "Compiles complete source and child closure without installing or executing it."
  @spec compile(term(), term()) :: {:ok, Program.t()} | {:error, Error.t()}
  def compile(source, context) do
    with {:ok, selection} <- new(),
         {:ok, source} <- source(source, selection) do
      Compiler.compile(source, context, selection.profile, selection.limits)
    end
  end

  @doc "Checks the entire retained program against a separately supplied current context."
  @spec current(term(), term()) :: :ok | {:error, Error.t()}
  def current(program, context) do
    with {:ok, selection} <- new() do
      Compiler.current(program, context, selection.profile, selection.limits)
    end
  end

  @doc "Revalidates and returns the full plain program using its retained context."
  @spec to_map(term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(program) do
    with {:ok, selection} <- new() do
      Compiler.to_map(program, selection.profile, selection.limits)
    end
  end

  @doc "Calculates complete pending work for explicitly supplied Collection@2 membership."
  @spec collect(term()) :: {:ok, Collection.t()} | {:error, Error.t()}
  def collect(input) do
    with {:ok, selection} <- new(),
         :ok <- format(input, "wotex.routines.collection-input@2") do
      Collection.evaluate(input, selection.profile, selection.limits)
    end
  end

  @doc "Checks the entire pending collection before selecting at most sixteen effect groups."
  @spec arbitrate(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def arbitrate(collection, dispositions) do
    with {:ok, selection} <- new(),
         :ok <- format(collection, "wotex.routines.collection@2"),
         :ok <- arbitration_envelope(collection, dispositions) do
      Arbitration.decide(collection, dispositions, 16, selection.profile, selection.limits)
    end
  end

  defp arbitration_envelope(%Collection{data: data} = collection, dispositions)
       when map_size(collection) == 2,
       do: arbitration_envelope(data, dispositions)

  defp arbitration_envelope(collection, dispositions) do
    options = [
      max_bytes: @limits["max_bytes"],
      max_depth: @limits["max_depth"],
      max_nodes: @limits["max_nodes"],
      max_string_bytes: @limits["max_string_bytes"],
      max_collection_size: @limits["max_collection_size"]
    ]

    envelope = %{
      "collection" => collection,
      "dispositions" => dispositions,
      "batch_limit" => 16,
      "profile" => @profile,
      "json_limits" => @limits
    }

    case Wotex.JSON.encode(envelope, options) do
      {:ok, _} -> :ok
      _ -> Error.refusal(:limit_or_json_error)
    end
  end

  defp format(%Collection{data: data}, expected), do: format(data, expected)
  defp format(%{"format" => value}, expected) when value == expected, do: :ok
  defp format(_, _), do: Error.refusal(:unsupported_decision_scope, "/format")

  defp source(bytes, selection) when is_binary(bytes),
    do: Codec.decode_source(bytes, selection.profile, selection.limits)

  defp source(value, selection), do: Source.new(value, selection.profile, selection.limits)

  defp exact(value, expected, code, path) do
    if value === expected, do: :ok, else: Error.refusal(code, path)
  end

  defp available do
    if Enum.all?(@api, fn {module, function, arity} ->
         Code.ensure_loaded?(module) and function_exported?(module, function, arity)
       end),
       do: :ok,
       else: Error.refusal(:routine_kernel_unavailable)
  end
end
