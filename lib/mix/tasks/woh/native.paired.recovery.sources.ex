defmodule Woh.Tool.NativePairedRecoverySources do
  @moduledoc false
  # Coordinator fixtures compile the actual production entry. This list adds
  # its transitive sources without introducing a conditional success backend.
  def names do
    ~w(NativeControllerPairingWire NativeControllerTLSClient NativeControllerAPIClient NativeControllerDomainClient
    NativeControllerAssociations NativeControllerAssociationStorage NativeControllerPairingCustody
    NativePairedKeychainCustodian NativePairedControllerSession SignedSetupPeer NativeSetupWire NativeTargetWire
    NativeCoreConnection NativeNetworkPreferences NativePrivateDocuments LocalHealthClient NativeBrokerClient
    NativeSetupSocket NativeRuleOperationWire NativeRuleClient NativeScheduleClient NativeScheduleWire
    NativePendingCodec NativePendingStorage NativePendingPairedCustody NativePendingRecoveryOperations
    NativePairedPendingRecoveryOperations NativePairedRecoveryCorrespondence NativePendingPublicationOwner)
  end
end
