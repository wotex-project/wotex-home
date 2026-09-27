defmodule Woh.Tool.ReleaseLegal do
  @moduledoc false

  @maude_license "32b1062f7da84967e7019d01ab805935caa7ab7321a7ced0e30ebe75e5df1670"
  @maude_notice "d7fcaf878bbae2f4539aa721a61d9d5f82b39c3109a6be440db3d1095c296f98"
  @apache_license "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
  @wotex_udp_license "f5b91731217e7913145b2b9ad04f63656a8a16d2b0e9ecca9bd256fbfc26a4d9"
  @wotex_udp_notice "bcca87818ff8c8cef81cbd63844a8606032e9fc43fdbbc26051b70764f5c3558"

  def maude_license, do: @maude_license
  def maude_notice, do: @maude_notice
  def apache_license, do: @apache_license
  def wotex_udp_license, do: @wotex_udp_license
  def wotex_udp_notice, do: @wotex_udp_notice

  def matches?(path, digest, limit \\ 20_000) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 and size <= limit ->
        Woh.Tool.Hash.sha256(path) == digest

      _ ->
        false
    end
  end
end
