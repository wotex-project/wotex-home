defmodule WotexHome.ControllerConnections.CertificateClock do
  @moduledoc """
  A short-lived trusted-client UTC uncertainty interval for certificate checks.

  Trusted host composition supplies the UTC range. This is not Home clock
  qualification and is never an ordinary API input. The interval advances by
  elapsed boot-monotonic time and expires without renewal. It adds refusals;
  it cannot override normal platform certificate validation.
  """
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

  @last_utc_ms 253_402_300_799_000
  @epoch :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
  @enforce_keys [:earliest, :latest, :observed, :expires, :wall]
  defstruct @enforce_keys

  def new(earliest, latest, lease_ms \\ 15_000) do
    if is_integer(earliest) and is_integer(latest) and earliest in 0..@last_utc_ms and
         latest in earliest..@last_utc_ms and is_integer(lease_ms) and lease_ms in 1..15_000 do
      observed = System.monotonic_time(:millisecond)

      {:ok,
       %__MODULE__{
         earliest: earliest,
         latest: latest,
         observed: observed,
         expires: observed + lease_ms,
         wall: System.os_time(:millisecond)
       }}
    else
      {:error, :tls_clock_uncertain}
    end
  end

  def bounds(%__MODULE__{
        earliest: first,
        latest: last,
        observed: observed,
        expires: expires,
        wall: wall
      }) do
    now = System.monotonic_time(:millisecond)
    wall_now = System.os_time(:millisecond)

    if is_integer(first) and is_integer(last) and first in 0..@last_utc_ms and
         last in first..@last_utc_ms and is_integer(observed) and is_integer(expires) and
         is_integer(wall) and
         expires in (observed + 1)..(observed + 15_000) and now >= observed and now < expires and
         wall_now >= wall and wall_now - wall < expires - observed and
         abs(wall_now - wall - (now - observed)) <= 2 and
         last + now - observed <= @last_utc_ms,
       do: {:ok, {first + now - observed, last + now - observed}},
       else: {:error, :tls_clock_uncertain}
  end

  def bounds(_), do: {:error, :tls_clock_uncertain}

  def covers?(certificate, clock) do
    certificate =
      if is_binary(certificate),
        do: :public_key.pkix_decode_cert(certificate, :otp),
        else: certificate

    span = certificate |> cert(:tbsCertificate) |> tbs(:validity)

    with {:ok, lower} <- instant(validity(span, :notBefore)),
         {:ok, upper} <- instant(validity(span, :notAfter)),
         {:ok, {first, last}} <- bounds(clock),
         do: lower <= first and last <= upper and lower <= upper,
         else: (_ -> false)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # PKIX's canonical UTC/generalized time forms only, through OTP's decoded
  # certificate record and calendar validation. No signature/path validation
  # is implemented here; SSL still rejects every platform validation failure.
  defp instant({:utcTime, [y1, y2 | rest]}) do
    if y1 in ?0..?9 and y2 in ?0..?9 do
      century = if (y1 - ?0) * 10 + y2 - ?0 >= 50, do: ~c"19", else: ~c"20"
      instant({:generalTime, century ++ [y1, y2 | rest]})
    else
      :invalid
    end
  end

  defp instant({:generalTime, value}) when is_list(value) do
    case List.to_string(value) do
      <<year::binary-size(4), month::binary-size(2), day::binary-size(2), hour::binary-size(2),
        minute::binary-size(2), second::binary-size(2), "Z">> ->
        parts = [year, month, day, hour, minute, second]

        values =
          if Enum.all?(parts, &Regex.match?(~r/\A[0-9]+\z/, &1)),
            do: Enum.map(parts, &Integer.parse/1),
            else: []

        case values do
          [{y, ""}, {m, ""}, {d, ""}, {h, ""}, {min, ""}, {s, ""}]
          when h in 0..23 and min in 0..59 and s in 0..59 ->
            if :calendar.valid_date({y, m, d}),
              do:
                {:ok,
                 (:calendar.datetime_to_gregorian_seconds({{y, m, d}, {h, min, s}}) - @epoch) *
                   1_000},
              else: :invalid

          _ ->
            :invalid
        end

      _ ->
        :invalid
    end
  end

  defp instant(_), do: :invalid
end
