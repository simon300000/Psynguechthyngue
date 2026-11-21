import CryptoKit
import Foundation

public enum ContentEvictionFinalization {
    /// V2 has a fresh identity so a legacy failed system-observation command
    /// cannot poison a still-recoverable explicit user eviction transaction.
    public static func command(for transaction: ContentEvictionTransaction, trigger: SyncTrigger) -> CoreCommand {
        let digest = Array(
            SHA256.hash(data: Data("psy-explicit-core-eviction-v2:\(transaction.id.uuidString.lowercased())".utf8))
                .prefix(16))
        let id = UUID(
            uuid: (
                digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
            ))
        return CoreCommand(
            id: id, kind: .evict, folderID: transaction.folderID, itemID: transaction.itemID,
            arguments: [
                "contentVersion": transaction.contentVersion.base64EncodedString(),
                "retentionTransactionID": transaction.id.uuidString.lowercased(),
            ],
            folderIncarnationDigest: transaction.folderIncarnationDigest,
            commandConfigurationRevision: transaction.configurationRevision,
            trigger: trigger, createdAt: transaction.createdAt)
    }

    public static func validate(_ command: CoreCommand, store: ContentRetentionStore) throws {
        guard command.kind == .evict, let token = command.arguments["retentionTransactionID"] else { return }
        guard let id = UUID(uuidString: token),
            let transaction = try store.pendingTransactions().first(where: { $0.id == id }),
            try store.coreEvictionIsRequested(transactionID: id),
            self.command(for: transaction, trigger: command.trigger).id == command.id,
            transaction.folderID == command.folderID, transaction.itemID == command.itemID,
            transaction.folderIncarnationDigest == command.folderIncarnationDigest,
            transaction.configurationRevision == command.commandConfigurationRevision,
            command.arguments["contentVersion"] == transaction.contentVersion.base64EncodedString(),
            command.arguments["systemEvictionObserved"] == nil
        else { throw CoreClientError.coreRejected("eviction_intent_superseded") }
    }
}
