defmodule WotexHome.Test.SchemaFixtures do
  @moduledoc false

  # Historical fixtures start from the latest empty profile schema. Strip its
  # exact tables before constructing an older independent schema/table set.
  def drop_portable_profiles do
    """
    DROP TABLE profile_qualification_history;
    DELETE FROM meta WHERE key='qualification_history_migration_revision';
    DROP TABLE profile_qualification_pins;
    DROP TABLE profile_rule_pins;
    DROP TABLE profile_request_pins;
    DROP TABLE profile_observation_pins;
    DROP TABLE profile_current;
    DROP TABLE profile_selection_history;
    DROP TABLE portable_profiles;
    DROP TABLE profile_operations;
    DELETE FROM meta WHERE key='profile_policy_generation';
    """
  end
end
