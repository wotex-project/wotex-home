defmodule ExMaude.Verification.Receipt do
  @moduledoc """
  Evidence from one isolated, bounded IoT model run.

  `semantic.digest` identifies the question and pinned model; `execution.run_id`
  identifies one attempt. `:bounded_complete` describes completion of the
  requested bounded command and does not establish an unbounded property.
  A finding's `witness` contains only the state/substitution returned by Maude,
  never a reconstructed transition trace.
  """

  @enforce_keys [:schema_version, :semantic, :execution]
  defstruct [:schema_version, :semantic, :execution]

  @type t :: %__MODULE__{
          schema_version: String.t(),
          semantic: map(),
          execution: map()
        }
end
