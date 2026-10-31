import Foundation

enum ProductAutofillFlow: String {
    case photoSelection = "a"
    case information = "b"
}

/// The flow is selected in Settings, independently of a product's AI ON/OFF choice.
enum ProductAutofillFlowPreference {
    static let key = "productAutofill.flow"
    static let defaults = makeDefaults(fixtureDirectory: ProductAppStorage.fixtureDirectory)

    static var current: ProductAutofillFlow {
        read(from: defaults)
    }

    static func resolve(rawValue: String?) -> ProductAutofillFlow {
        rawValue.flatMap(ProductAutofillFlow.init(rawValue:)) ?? .photoSelection
    }

    static func read(from defaults: UserDefaults) -> ProductAutofillFlow {
        resolve(rawValue: defaults.string(forKey: key))
    }

    static func write(_ flow: ProductAutofillFlow, to defaults: UserDefaults) {
        defaults.set(flow.rawValue, forKey: key)
    }

    static func makeDefaults(fixtureDirectory: URL?) -> UserDefaults {
        guard let fixtureDirectory else { return .standard }
        // A fixture launch must never change the person's actual selection. Using
        // the store token also preserves its choice across a fixture relaunch.
        guard let defaults = UserDefaults(suiteName: fixtureSuiteName(for: fixtureDirectory)) else {
            preconditionFailure("Unable to create the isolated flow preference store")
        }
        return defaults
    }

    static func fixtureSuiteName(for directory: URL) -> String {
        "com.dobby.product-autofill-flow.fixture.\(directory.lastPathComponent)"
    }
}
