// SPDX-License-Identifier: MIT

import Foundation
import Mobilebridge

// This source is compiled and linked by release verification. It is not run;
// its purpose is to make the Swift-imported bridge surface a checked contract.
func verifyMobilebridgeImporter(_ core: MobilebridgeCore) throws {
    var nativeError: NSError?
    _ = MobilebridgeCoreRevision()
    _ = MobilebridgeNewCore("/private/tmp/mobilebridge-smoke", Data(), &nativeError)
    _ = core.deviceID()
    let _: Data? = core.identityBlob()
    try core.start()
    let _: String = core.snapshotJSON("{}")
    let _: String = core.networkTransferTotalsJSON("{}")
    let _: String = core.commandJSON("{}")
    let _: String = core.queryJSON("{}")
    let _: String = core.readRangeJSON("{}")
    let _: String = core.acknowledgeCommand("smoke-request")
    core.requestCancel()
    try core.stop()
    try core.close()
}
