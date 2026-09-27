defmodule Woh.Tool.NativeSnapshotSmoke do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    cases =
      for mode <- ~w(valid changed full) do
        count = if mode == "full", do: 11, else: 2

        exchanges =
          for index <- 0..(count - 1) do
            {request(mode, index), response(mode, index)}
          end

        %{mode: mode, exchanges: exchanges}
      end

    NativeFixture.run(project, "LocalSnapshotSmoke.swift", cases)
  end

  defp request(mode, index) do
    after_cursor =
      cond do
        index == 0 ->
          nil

        mode == "full" ->
          %{"thing_id" => "light:#{pad(index * 100 - 1, 4)}", "capability_key" => "power"}

        true ->
          %{"thing_id" => "light:desk", "capability_key" => "power"}
      end

    %{
      "api_version" => 1,
      "operation" => "snapshot",
      "credential" => NativeFixture.credential(),
      "watermark" => if(index == 0, do: nil, else: 12),
      "after" => after_cursor,
      "page_size" => 100
    }
  end

  defp response("changed", 1),
    do: %{"api_version" => 1, "outcome" => "error", "reason" => "resnapshot_required"}

  defp response("full", index) do
    start = index * 100
    stop = min(start + 100, 1_024)

    items =
      for number <- start..(stop - 1) do
        %{
          "thing_id" => "light:#{pad(number, 4)}",
          "capability_key" => "power",
          "quality" => "reported",
          "trust" => "unauthenticated_local",
          "value" => %{"type" => "boolean", "value" => true},
          "revision" => 10
        }
      end

    %{
      "api_version" => 1,
      "outcome" => "ok",
      "snapshot" => %{
        "authority_epoch" => 1,
        "watermark" => 12,
        "items" => items,
        "next_after" =>
          if(stop < 1_024,
            do: %{"thing_id" => "light:#{pad(stop - 1, 4)}", "capability_key" => "power"},
            else: nil
          )
      }
    }
  end

  defp response(_mode, index) do
    capability = if index == 0, do: "power", else: "brightness"

    value =
      if index == 0,
        do: %{"type" => "boolean", "value" => true},
        else: %{"type" => "fraction", "ppm" => 400_000}

    %{
      "api_version" => 1,
      "outcome" => "ok",
      "snapshot" => %{
        "authority_epoch" => 1,
        "watermark" => 12,
        "items" => [
          %{
            "thing_id" => if(index == 0, do: "light:desk", else: "light:next"),
            "capability_key" => capability,
            "quality" => "reported",
            "trust" => "unauthenticated_local",
            "value" => value,
            "revision" => 10 + index
          }
        ],
        "next_after" =>
          if(index == 0,
            do: %{"thing_id" => "light:desk", "capability_key" => "power"},
            else: nil
          )
      }
    }
  end

  defp pad(number, width), do: number |> Integer.to_string() |> String.pad_leading(width, "0")
end

defmodule Woh.Tool.NativeReadViewSmoke do
  @moduledoc false

  alias Woh.Tool.NativeFixture

  def run(project) do
    cases =
      for mode <- ~w(valid changed) do
        exchanges = for index <- 0..2, do: {request(index), response(mode, index)}
        %{mode: mode, exchanges: exchanges}
      end

    NativeFixture.run(project, "LocalReadViewSmoke.swift", cases)
  end

  defp request(index) when index < 2 do
    %{
      "api_version" => 1,
      "operation" => "catalogue",
      "credential" => NativeFixture.credential(),
      "watermark" => if(index == 0, do: nil, else: 12),
      "after" => if(index == 0, do: nil, else: "light:09"),
      "page_size" => 10
    }
  end

  defp request(2) do
    %{
      "api_version" => 1,
      "operation" => "snapshot",
      "credential" => NativeFixture.credential(),
      "watermark" => 12,
      "after" => nil,
      "page_size" => 100
    }
  end

  defp response("changed", 2),
    do: %{"api_version" => 1, "outcome" => "error", "reason" => "resnapshot_required"}

  defp response(_mode, 2) do
    %{
      "api_version" => 1,
      "outcome" => "ok",
      "snapshot" => %{
        "authority_epoch" => 1,
        "watermark" => 12,
        "items" => [],
        "next_after" => nil
      }
    }
  end

  defp response(_mode, index) do
    items = if index == 0, do: Enum.map(0..9, &thing/1), else: [thing(10)]

    %{
      "api_version" => 1,
      "outcome" => "ok",
      "catalogue" => %{
        "authority_epoch" => 1,
        "watermark" => 12,
        "items" => items,
        "next_after" => if(index == 0, do: "light:09", else: nil)
      }
    }
  end

  defp thing(index) do
    id = "light:#{index |> Integer.to_string() |> String.pad_leading(2, "0")}"

    %{
      "id" => id,
      "role" => "Light",
      "profile_ref" => "fixture:light:1",
      "capabilities" => [
        %{
          "thing_id" => id,
          "role" => "Light",
          "profile_ref" => "fixture:light:1",
          "key" => "power",
          "value_kind" => "boolean",
          "risk_class" => "ordinary",
          "operations" => if(index == 1, do: ["read"], else: ["read", "write"])
        }
      ],
      "resource_revision" => 0
    }
  end
end

defmodule Mix.Tasks.Woh.Native.Snapshot.Smoke do
  @moduledoc """
  Exercises Swift snapshot paging against an independent socket fixture.

  Run `mix woh.native.snapshot.smoke` to check two-page reads, rejection when
  the watermark changes and the 1,024-row client bound over eleven pages.
  The fixture checks every request cursor and page size exactly.
  """

  @shortdoc "Smoke-test Swift snapshot paging"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeSnapshotSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native snapshot paging, 1,024-row bound, and resnapshot rejection passed"
        )

      {:error, reason} ->
        Mix.raise("native snapshot smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.snapshot.smoke")
end

defmodule Mix.Tasks.Woh.Native.Read.View.Smoke do
  @moduledoc """
  Exercises Swift catalogue and snapshot reads at one revision.

  Run `mix woh.native.read.view.smoke` to check catalogue paging, its shared
  snapshot watermark and rejection if that watermark changes. The peer checks
  each framed request against the exact expected scope and cursor.
  """

  @shortdoc "Smoke-test Swift revision-stable read view"
  @requirements ["loadpaths"]
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    case Woh.Tool.NativeReadViewSmoke.run(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "native catalogue and snapshot use one watermark; changed revision rejected"
        )

      {:error, reason} ->
        Mix.raise("native read view smoke failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.read.view.smoke")
end
