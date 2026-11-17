enum ConnectedAccountState: Equatable {
    case disconnected
    case connected(account: String)

    var account: String? {
        switch self {
        case .disconnected:
            nil
        case let .connected(account):
            account
        }
    }

    var isConnected: Bool {
        switch self {
        case .disconnected:
            false
        case .connected:
            true
        }
    }
}
