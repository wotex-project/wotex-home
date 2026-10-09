defmodule WotexHome.ControllerCertificateClockTest do
  use ExUnit.Case, async: true
  alias WotexHome.ControllerConnections.CertificateClock
  require Record

  Record.defrecordp(
    :cert,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  test "UTC intervals advance together using monotonic elapsed time and cannot renew" do
    {:ok, clock} = CertificateClock.new(1_000, 2_000)

    advanced = %{
      clock
      | observed: clock.observed - 1_000,
        expires: clock.expires - 1_000,
        wall: clock.wall - 1_000
    }

    assert {:ok, {first, last}} = CertificateClock.bounds(advanced)
    assert first >= 2_000
    assert last - first == 1_000
    now = System.monotonic_time(:millisecond)

    assert CertificateClock.bounds(%{clock | observed: now - 16_000, expires: now - 1_000}) ==
             {:error, :tls_clock_uncertain}

    assert CertificateClock.bounds(%{clock | observed: now + 10_000, expires: now + 11_000}) ==
             {:error, :tls_clock_uncertain}

    assert CertificateClock.bounds(%{clock | expires: clock.observed + 15_001}) ==
             {:error, :tls_clock_uncertain}

    # macOS OTP uses CLOCK_UPTIME_RAW, which pauses during suspension. The
    # independent wall/monotonic disagreement adds a refusal, never authority.
    assert CertificateClock.bounds(%{clock | wall: clock.wall - 1_000}) ==
             {:error, :tls_clock_uncertain}

    assert CertificateClock.bounds(%{clock | wall: clock.wall + 1_000}) ==
             {:error, :tls_clock_uncertain}
  end

  test "closed integer UTC bounds and a finite lease refuse malformed clocks" do
    for args <- [
          {-1, 1, 1},
          {2, 1, 1},
          {1, 1, 0},
          {1, 1, 15_001},
          {1.0, 2, 1},
          {1, 2.0, 1},
          {1, 2, 1.0},
          {0, 253_402_300_799_001, 1}
        ] do
      {first, last, lease} = args
      assert CertificateClock.new(first, last, lease) == {:error, :tls_clock_uncertain}
    end

    for value <- [nil, %{}, true, [], "clock"],
        do: assert(CertificateClock.bounds(value) == {:error, :tls_clock_uncertain})
  end

  test "the full uncertainty interval must lie inside canonical certificate dates" do
    center = DateTime.to_unix(~U[2026-10-09 12:00:00Z], :millisecond)
    {:ok, narrow} = CertificateClock.new(center, center + 1_000)
    certificate = certificate({:utcTime, ~c"261008120000Z"}, {:generalTime, ~c"20261010120000Z"})
    assert CertificateClock.covers?(certificate, narrow)
    {:ok, crossing} = CertificateClock.new(center, center + 86_401_000)
    refute CertificateClock.covers?(certificate, crossing)
    refute CertificateClock.covers?(certificate, nil)
    refute CertificateClock.covers?("not DER", narrow)

    refute CertificateClock.covers?(
             certificate({:utcTime, ~c"490101000000Z"}, {:generalTime, ~c"20500101000000Z"}),
             narrow
           )
  end

  test "malformed or alternate X.509 time spellings cannot pass the extra guard" do
    center = DateTime.to_unix(~U[2026-10-09 12:00:00Z], :millisecond)
    {:ok, clock} = CertificateClock.new(center, center)

    for time <- [
          {:generalTime, ~c"+0261008120000Z"},
          {:generalTime, ~c"202610081200Z"},
          {:generalTime, ~c"20261008120000+0000"},
          {:generalTime, ~c"20261308120000Z"},
          {:generalTime, ~c"20260230120000Z"},
          {:generalTime, ~c"20261008120060Z"},
          {:utcTime, ~c"aa1008120000Z"},
          {:utcTime, ~c"2610081200Z"},
          {:utcTime, nil},
          {:unknown, []}
        ] do
      refute CertificateClock.covers?(
               certificate(time, {:generalTime, ~c"20261010120000Z"}),
               clock
             )
    end
  end

  defp certificate(first, last),
    do: cert(tbsCertificate: tbs(validity: validity(notBefore: first, notAfter: last)))
end
