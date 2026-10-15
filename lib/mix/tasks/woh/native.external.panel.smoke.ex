defmodule Mix.Tasks.Woh.Native.External.Panel.Smoke do
  @moduledoc """
  Checks selected external-profile first decisions against an actual private Store.

  Run `mix woh.native.external.panel.smoke` on the supported macOS toolchain.
  The task compiles the production driver, model and panel and exercises both
  quantity families, separate human confirmation, dropped replies, durable pending
  recovery, changed reviews, decision retirement before send and paired refusal.
  Prepared views render at responsive widths with ordinary and enlarged text.

  Credentials travel on stdin and fixture data stays in disposable private
  directories. Passing software checks do not establish installed signing,
  accessibility, source presence or physical device qualification.
  """

  use Mix.Task
  @requirements ["loadpaths"]
  @shortdoc "Check selected native external-profile review and confirmation"

  def run([]) do
    case Woh.Tool.NativeExternalMutationLive.run(File.cwd!(), true) do
      :ok ->
        Mix.shell().info(
          "native external selected decisions, Store recovery, retirement races and responsive panel checks passed"
        )

      {:error, reason} ->
        Mix.raise("native external panel smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.external.panel.smoke")
end
