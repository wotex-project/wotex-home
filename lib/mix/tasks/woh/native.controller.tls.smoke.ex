defmodule Mix.Tasks.Woh.Native.Controller.Tls.Smoke do
  @moduledoc "Checks Apple controller TLS against independent OTP peers; does not provision a real controller."
  @shortdoc "Check native controller TLS trust and bounded bootstrap"
  @requirements ["loadpaths"]
  use Mix.Task
  @compile {:no_warn_undefined, WotexHome.TestSupport.ControllerTLSFixture}
  alias Woh.Tool.Command

  def run([]) do
    Code.require_file("test/support/controller_tls_fixture.exs")

    root =
      Path.join(
        System.tmp_dir!(),
        "woh-controller-native-tls-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    executable = Path.join(root, "controller-tls-smoke")

    try do
      args = [
        "-parse-as-library",
        "-warnings-as-errors",
        "-swift-version",
        "6",
        "-module-cache-path",
        Path.join(root, "cache"),
        "-target",
        "arm64-apple-macos15.0",
        Path.expand("native/macos/Sources/NativeControllerPairingWire.swift"),
        Path.expand("native/macos/Sources/NativeControllerTLSClient.swift"),
        Path.expand("native/macos/Tests/NativeControllerTLSClientSmoke.swift"),
        "-o",
        executable
      ]

      case Command.run_diagnostic("swiftc", args, 1_048_576, 60_000) do
        {:ok, _} -> :ok
        {:error, reason} -> Mix.raise("native controller TLS compiler failed: #{reason}")
      end

      fixture = peer().create(Path.join(root, "certificates"))

      cases = [
        {"valid", :paired, "paired"},
        {"valid", :fragmented, "paired"},
        {"valid", :refused, "refused"},
        {"wrong_name", :paired, "tlsPeerUnverified"},
        {"common_name_only", :paired, "tlsPeerUnverified"},
        {"uri_name_only", :paired, "tlsPeerUnverified"},
        {"wrong_purpose", :paired, "tlsPeerUnverified"},
        {"expired", :paired, "tlsPeerUnverified"},
        {"future", :paired, "tlsPeerUnverified"},
        {"unknown_critical", :paired, "tlsPeerUnverified"},
        {"unknown_ca", :paired, "tlsPeerUnverified"},
        {"corrupt", :paired, "tlsPeerUnverified"},
        {"changed", :paired, "tlsPinChanged"},
        {"valid", :lost, "outcomeUnknown"},
        {"valid", :oversize, "outcomeUnknown"},
        {"valid", :empty, "outcomeUnknown"},
        {"valid", :truncated, "outcomeUnknown"},
        {"valid", :wrong_digest, "outcomeUnknown"},
        {"valid", :widened, "outcomeUnknown"},
        {"valid", :slow_header, "outcomeUnknown"},
        {"valid", :slow_body, "outcomeUnknown"}
      ]

      for {variant, mode, expected} <- cases do
        {port, task} = peer().peer(fixture, variant, mode)
        invited_variant = if variant == "changed", do: "valid", else: variant
        invitation = peer().invitation(fixture, port, invited_variant)

        check(executable, invitation, expected,
          deadline: mode in [:slow_header, :slow_body],
          name: "#{variant}/#{mode}"
        )

        require_peer(
          task,
          if(expected in ["tlsPeerUnverified", "tlsPinChanged"],
            do: :no_application_bytes,
            else: {:request, peer().request_body()}
          )
        )
      end

      for identity <- [["ipv4", "127.0.0.1"], ["ipv6", "0000:0000:0000:0000:0000:0000:0000:0001"]] do
        {port, task} = peer().peer(fixture)
        check(executable, peer().invitation(fixture, port, "valid", identity), "paired")
        require_peer(task, {:request, peer().request_body()})
      end

      {port, task} = peer().peer(fixture, "valid", :paired, ip: {0, 0, 0, 0, 0, 0, 0, 1})

      invitation =
        peer().invitation(fixture, port)
        |> Map.put("endpoint", ["ipv6", "0000:0000:0000:0000:0000:0000:0000:0001", port])

      check(executable, invitation, "paired")
      require_peer(task, {:request, peer().request_body()})

      {port, task} = peer().peer(fixture, "valid", :paired, ip: {0, 0, 0, 0, 0, 0, 0, 1})

      invitation =
        peer().invitation(fixture, port) |> Map.put("endpoint", ["dns", "localhost", port])

      check(executable, invitation, "paired", name: "DNS IPv6 endpoint")
      require_peer(task, {:request, peer().request_body()})

      {port, task} = peer().peer(fixture, "valid", :paired, versions: [:"tlsv1.2"])
      check(executable, peer().invitation(fixture, port), "tlsPeerUnverified")
      require_peer(task, :no_application_bytes)
      {port, task} = peer().peer(fixture)

      check(executable, peer().invitation(fixture, port), "tlsClockUncertain",
        uncertainty: 86_401_000
      )

      require_peer(task, :no_application_bytes)

      check(
        executable,
        peer().invitation(fixture, 49_999) |> Map.put("trust_anchor", "YWJj"),
        "invalidTrust"
      )

      check(
        executable,
        peer().invitation(fixture, 49_999)
        |> Map.put("endpoint", ["ipv6", "fe80:0000:0000:0000:0000:0000:0000:0001", 49_999]),
        "tlsClientInterfaceRequired"
      )

      for cancel <- [false, true] do
        {port, task} = silent_peer()

        check(
          executable,
          peer().invitation(fixture, port),
          if(cancel, do: "cancelled", else: "tlsHandshakeTimeout"),
          cancel: cancel,
          deadline: not cancel
        )

        require_peer(task, :closed)
      end

      Mix.shell().info(
        "native controller TLS 31 independent trust, frame, deadline and cancellation cases passed"
      )
    after
      File.rm_rf!(root)
    end
  end

  def run(_), do: Mix.raise("usage: mix woh.native.controller.tls.smoke")
  defp peer, do: WotexHome.TestSupport.ControllerTLSFixture

  defp check(executable, invitation, expected, opts \\ []) do
    now = System.system_time(:millisecond)

    body =
      JSON.encode!(%{
        "invitation" => peer().invitation_body(invitation),
        "request" => peer().request_body(),
        "earliest" => now,
        "latest" => now + Keyword.get(opts, :uncertainty, 0),
        "expected" => expected,
        "deadline" => Keyword.get(opts, :deadline, false),
        "cancel" => Keyword.get(opts, :cancel, false)
      })

    # Synthetic public records only; native diagnostics contain closed outcome
    # names and never print the supplied invitation, certificate or frame.
    case Command.run_diagnostic(
           executable,
           [],
           16_384,
           8_000,
           <<byte_size(body)::32, body::binary>>
         ) do
      {:ok, output} ->
        unless String.trim(output) == "native controller TLS case passed",
          do: Mix.raise("native controller TLS case did not complete")

      {:error, reason} ->
        Mix.raise(
          "native controller TLS #{Keyword.get(opts, :name, expected)} case failed: #{reason}"
        )
    end
  end

  defp require_peer(task, expected) do
    unless Task.await(task, 8_000) == expected,
      do: Mix.raise("native controller TLS peer observed unexpected application bytes")
  end

  defp silent_peer do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        try do
          {:ok, socket} = :gen_tcp.accept(listener, 7_000)

          try do
            drain(socket, 0)
          after
            :gen_tcp.close(socket)
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    {port, task}
  end

  defp drain(socket, count) when count < 65_536 do
    case :gen_tcp.recv(socket, 0, 7_000) do
      {:ok, bytes} -> drain(socket, count + byte_size(bytes))
      {:error, :closed} -> :closed
      _ -> :not_closed
    end
  end
end
