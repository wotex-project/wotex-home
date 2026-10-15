import SwiftUI

struct NativePowerReceiptPanel: View {
    @ObservedObject var health: HealthViewModel
    let localSelected: Bool
    var body: some View {
        HomeSection(title: "Power request receipts") {
            TextField("Authority epoch", text: $health.authorityEpochInput)
            TextField("Operation ID", text: $health.operationIDInput)
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading) { controls }
            }
            Text(health.receiptStatus).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if health.receiptUsesRecordedPair {
                Text("Read from the original paired controller. This lookup does not retry or cancel the request.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = health.receiptError { Text(error).foregroundStyle(.red) }
            Text("Look up the original ID after uncertainty. Cancel withdraws held or still-queued work; a handed-off packet cannot be recalled.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var controls: some View {
        Group {
            if health.hasLastPairedReceipt { Button("Use Last Paired Original") { health.useLastPairedReceipt() } }
            Button("Look Up Original") { health.lookupReceipt() }.disabled(health.operationIDInput.isEmpty)
            Button("Cancel Pending") { health.cancelPendingRequest() }.disabled(health.operationIDInput.isEmpty || health.receiptUsesRecordedPair || !localSelected)
            Button("Retry Original Power") { health.retryPower() }.disabled(!health.hasUnconfirmedPower || health.receiptUsesRecordedPair)
        }
    }
}
