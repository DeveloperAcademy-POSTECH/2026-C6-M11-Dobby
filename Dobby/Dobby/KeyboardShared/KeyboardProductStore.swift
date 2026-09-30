import Foundation

nonisolated struct KeyboardProductSnapshot: Codable, Equatable {
    let productName: String
    let description: String
    let brand: String
    let measurements: String
    let price: String
    let length: String
    let waist: String
    let thigh: String
}

nonisolated enum KeyboardProductStore {
    static let appGroupID = "group.com.dobby.Dobby"
    private static let productKey = "keyboard.currentProduct.v1"

    static func save(_ snapshot: KeyboardProductSnapshot) throws {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            throw StoreError.appGroupUnavailable
        }
        defaults.set(try JSONEncoder().encode(snapshot), forKey: productKey)
    }

    static func load() -> KeyboardProductSnapshot? {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: productKey) else {
            return nil
        }
        return try? JSONDecoder().decode(KeyboardProductSnapshot.self, from: data)
    }

    enum StoreError: Error {
        case appGroupUnavailable
    }
}

