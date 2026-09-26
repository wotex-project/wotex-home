defmodule ExMaude.NIFCase do
  @moduledoc """
  Case template for tests that need the compiled Rust NIF.

  The NIF is only present when `EX_MAUDE_BUILD=1` is set, or when a populated
  `checksum-Elixir.ExMaude.Backend.NIF.Native.exs` triggers a precompiled
  download. With neither, the hidden native adapter used by
  `ExMaude.Backend.NIF` keeps its `:erlang.nif_error(:nif_not_loaded)` stubs
  and every call raises.

  These tests carry both `:nif` and `:integration`. ExUnit resolves `include`
  ahead of `exclude`, so the documented `mix test --include integration` pulls
  them in even though `:nif` is excluded, and they then fail on any machine
  that has not built the NIF. Skipping is the honest outcome — the code was
  not exercised, which is not the same as the code being wrong.

  The skip is applied as a compile-time `@moduletag`, not from `setup`.
  ExUnit's `setup` may only return `:ok`, a keyword, or a map; returning
  `:skip` raises `RuntimeError` and turns a skip into a failure.

  Build the NIF with:

      EX_MAUDE_BUILD=1 mix compile --force
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import ExMaude.NIFCase

      unless ExMaude.NIFCase.nif_available?() do
        @moduletag skip: "NIF not built — set EX_MAUDE_BUILD=1 and recompile"
      end
    end
  end

  @doc "Whether the NIF function table was populated at load time."
  @spec nif_available?() :: boolean()
  def nif_available? do
    ExMaude.Backend.NIF.Native.nif_loaded()
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
