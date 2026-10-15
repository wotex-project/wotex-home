defmodule WotexHome do
  @moduledoc """
  Local Home authority, durable state and typed device semantics.

  Home is one OTP application. `WotexHome.Authority` coordinates application
  use cases; `WotexHome.Durable.Store` owns the single SQLite writer, revisions,
  receipts and host lock. Transport adapters and native presentation call that
  boundary rather than receiving a database connection.

  Start with `WotexHome.Semantics.Thing` and
  `WotexHome.Semantics.Observation` for declarations and reported evidence,
  `WotexHome.Discovery.Candidate` for untrusted introductions, and
  `WotexHome.Rules.Rule` for inert automation drafts.
  `WotexHome.Profiles.AuthoringContract` describes the installed profile grammar;
  `WotexHome.Qualification.Programme` describes qualification evidence gaps.
  Constructing these values does not enroll a device or admit an effect.

  `WotexHome.Application` starts an empty Home supervisor when no data root is
  configured. With an explicit private root it starts `WotexHome.Host`; trusted
  embedded callers may instead supervise `WotexHome.Host.start_link/1` directly.
  `WotexHome.CLI` uses the private authenticated socket without owning Store.

  Staging, admission, durable handoff, protocol acknowledgement and reported
  state remain distinct. Physical dispatch is disabled by default and requires
  its current guards and qualification; successful compilation or synthetic
  fixtures do not establish physical device behavior.
  """
end
