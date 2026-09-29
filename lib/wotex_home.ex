defmodule WotexHome do
  @moduledoc """
  Pure Home domain contracts.

  No controller, driver, credential store or network listener is started by
  loading this application. Runtime authority is a later delivery gate.

  The modules under `Semantics`, `Discovery`, `Rules` and `Qualification`
  describe values and decisions at their respective boundaries. The opted-in
  `WotexHome.Host` owns the local Store and API when a private data directory
  is configured. Start with those modules when integrating a new device or
  input surface; all effects still converge on the same durable authority.
  """
end
