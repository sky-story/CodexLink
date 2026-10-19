import Foundation

// Optional fields default off. The control protocol version gates mutating shared
// operations independently of read-only features and the Claude channel.
struct BridgeCapabilities: Equatable {
    let sharedControl: Bool
    let sessionSettings: Bool
    let turnStateSnapshot: Bool
    let macTerminalOpen: Bool
    let claudeChannels: Bool

    init(_ payload: JSONValue?) {
        let fields = payload?.objectValue ?? [:]
        let shared = fields["sharedSession"]?.boolValue == true
        sharedControl = shared && fields["controlProtocol"]?.intValue == 1
        sessionSettings = sharedControl && fields["sessionSettings"]?.boolValue == true
        turnStateSnapshot = shared && fields["turnStateSnapshot"]?.boolValue == true
        macTerminalOpen = sharedControl && fields["macTerminalOpen"]?.boolValue == true
        claudeChannels = fields["claudeChannels"]?.boolValue == true
    }
}

extension CodexService {
    var usesSharedSessionComposer: Bool { supportsSharedSessionControl || lastNegotiatedSharedSession }

    func applyBridgeCapabilities(_ payload: JSONValue?) {
        let capabilities = BridgeCapabilities(payload)
        if let fields = payload?.objectValue {
            lastNegotiatedSharedSession = fields["sharedSession"]?.boolValue == true
        }
        supportsSharedSessionControl = capabilities.sharedControl
        supportsSharedSessionSettings = capabilities.sessionSettings
        supportsTurnStateSnapshot = capabilities.turnStateSnapshot
        supportsMacTerminalOpen = capabilities.macTerminalOpen
        supportsClaudeChannels = capabilities.claudeChannels
    }
}
