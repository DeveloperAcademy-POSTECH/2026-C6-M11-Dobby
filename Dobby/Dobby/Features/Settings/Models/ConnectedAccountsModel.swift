import Foundation
import Observation

enum ConnectedAccountPlatform: String, Identifiable {
    case instagram
    case cafe24

    var id: Self { self }

    var title: String {
        switch self {
        case .instagram: "Instagram"
        case .cafe24: "카페24"
        }
    }
}

@MainActor
@Observable
final class ConnectedAccountsModel {
    private let instagramClient: InstagramIntegrationClient
    private let cafe24Client: Cafe24IntegrationClient

    private(set) var instagramAccount: InstagramAccount?
    private(set) var cafe24MallID: String?
    private(set) var loadingPlatforms: Set<ConnectedAccountPlatform> = []
    var message: String?

    init(
        instagramClient: InstagramIntegrationClient? = nil,
        cafe24Client: Cafe24IntegrationClient? = nil
    ) {
        self.instagramClient = instagramClient ?? InstagramIntegrationClient()
        self.cafe24Client = cafe24Client ?? Cafe24IntegrationClient()
    }

    /// 두 플랫폼의 현재 연결 상태를 순차적으로 확인합니다.
    func requestAccounts() async {
        await requestInstagramAccount()
        await requestCafe24Account()
    }

    func connectInstagram() async {
        guard !loadingPlatforms.contains(.instagram) else { return }
        loadingPlatforms.insert(.instagram)
        defer { loadingPlatforms.remove(.instagram) }

        do {
            instagramAccount = try await instagramClient.connect()
        } catch {
            message = error.localizedDescription
        }
    }

    func connectCafe24(mallID: String) async {
        guard !loadingPlatforms.contains(.cafe24) else { return }
        loadingPlatforms.insert(.cafe24)
        defer { loadingPlatforms.remove(.cafe24) }

        do {
            try await cafe24Client.connect(mallID: mallID)
            let status = try await cafe24Client.connectionStatus()
            cafe24MallID = status.connected ? status.mallID : nil
        } catch {
            message = error.localizedDescription
        }
    }

    func disconnect(_ platform: ConnectedAccountPlatform) async {
        guard !loadingPlatforms.contains(platform) else { return }
        loadingPlatforms.insert(platform)
        defer { loadingPlatforms.remove(platform) }

        do {
            switch platform {
            case .instagram:
                try await instagramClient.disconnect()
                instagramAccount = nil
            case .cafe24:
                try await cafe24Client.disconnect()
                cafe24MallID = nil
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func isLoading(_ platform: ConnectedAccountPlatform) -> Bool {
        loadingPlatforms.contains(platform)
    }

    private func requestInstagramAccount() async {
        loadingPlatforms.insert(.instagram)
        defer { loadingPlatforms.remove(.instagram) }

        do {
            instagramAccount = try await instagramClient.account()
        } catch {
            message = error.localizedDescription
        }
    }

    private func requestCafe24Account() async {
        loadingPlatforms.insert(.cafe24)
        defer { loadingPlatforms.remove(.cafe24) }

        do {
            let status = try await cafe24Client.connectionStatus()
            cafe24MallID = status.connected ? status.mallID : nil
        } catch {
            message = error.localizedDescription
        }
    }
}
