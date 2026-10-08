defmodule WotexHome.Test.SchemaFixtures do
  @moduledoc false

  # Historical fixtures start from the latest empty profile schema. Strip its
  # exact tables before constructing an older independent schema/table set.
  def drop_portable_profiles do
    drop_transfer_acceptance() <>
      """
      DROP TABLE controller_retirements;
      DROP TABLE controller_identity;
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

  def drop_transfer_acceptance do
    """
    DROP TABLE schedule_watermarks; DROP TABLE schedule_considerations; DROP TABLE schedule_lifecycle_operations; DROP TABLE schedule_admissions;
    DROP TABLE native_target_operations;
    DROP TABLE controller_acceptances;
    ALTER TABLE host_maintenance_operations RENAME TO host_maintenance_newer;
    CREATE TABLE host_maintenance_operations (
      principal_id TEXT NOT NULL REFERENCES principals(principal_id),
      authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
      operation_id TEXT NOT NULL,
      action TEXT NOT NULL CHECK (action IN ('begin', 'end')),
      expected_revision INTEGER NOT NULL CHECK (expected_revision >= 0),
      begin_revision INTEGER NOT NULL CHECK (begin_revision >= 0),
      revision INTEGER PRIMARY KEY REFERENCES authority_journal(revision),
      fence_revision INTEGER NOT NULL CHECK (fence_revision >= 0),
      rule_generation INTEGER NOT NULL CHECK (rule_generation >= 0),
      affected_requests INTEGER NOT NULL CHECK (affected_requests BETWEEN 0 AND 1024),
      unknown_outcomes INTEGER NOT NULL CHECK (unknown_outcomes BETWEEN 0 AND affected_requests),
      UNIQUE (principal_id, authority_epoch, operation_id)
    );
    INSERT INTO host_maintenance_operations SELECT * FROM host_maintenance_newer;
    DROP TABLE host_maintenance_newer;
    """
  end
end
