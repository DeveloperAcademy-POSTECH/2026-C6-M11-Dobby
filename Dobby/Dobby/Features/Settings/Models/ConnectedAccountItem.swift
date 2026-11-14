struct ConnectedAccountItem: Identifiable, Equatable {
    let platform: ConnectedAccountPlatform
    let state: ConnectedAccountState
    let isWorking: Bool

    var id: ConnectedAccountPlatform {
        platform
    }
}
