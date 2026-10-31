import Foundation
import Testing
@testable import Dobby

@MainActor
struct ProductAutofillFlowPreferenceTests {
    @Test func anUnsetOrUnrecognizedPreferenceKeepsTheExistingPhotoSelectionFlow() {
        #expect(ProductAutofillFlowPreference.resolve(rawValue: nil) == .photoSelection)
        #expect(ProductAutofillFlowPreference.resolve(rawValue: "unknown") == .photoSelection)
        #expect(ProductAutofillFlowPreference.resolve(rawValue: "") == .photoSelection)
        #expect(ProductAutofillFlowPreference.resolve(rawValue: "b") == .information)
        #expect(ProductAutofillFlowPreference.resolve(rawValue: "a") == .photoSelection)
    }

    @Test func selectionPersistsWhenTheSameFixtureStoreIsReopened() {
        let directory = makeFixtureDirectory()
        let defaults = ProductAutofillFlowPreference.makeDefaults(fixtureDirectory: directory)
        defer { defaults.removePersistentDomain(forName: ProductAutofillFlowPreference.fixtureSuiteName(for: directory)) }

        #expect(ProductAutofillFlowPreference.read(from: defaults) == .photoSelection)
        ProductAutofillFlowPreference.write(.information, to: defaults)
        let reopened = ProductAutofillFlowPreference.makeDefaults(fixtureDirectory: directory)
        #expect(ProductAutofillFlowPreference.read(from: reopened) == .information)

        ProductAutofillFlowPreference.write(.photoSelection, to: reopened)
        #expect(ProductAutofillFlowPreference.read(from: defaults) == .photoSelection)
    }

    @Test func independentFixtureStoresDoNotShareTheSelection() {
        let firstDirectory = makeFixtureDirectory()
        let secondDirectory = makeFixtureDirectory()
        let first = ProductAutofillFlowPreference.makeDefaults(fixtureDirectory: firstDirectory)
        let second = ProductAutofillFlowPreference.makeDefaults(fixtureDirectory: secondDirectory)
        defer {
            first.removePersistentDomain(forName: ProductAutofillFlowPreference.fixtureSuiteName(for: firstDirectory))
            second.removePersistentDomain(forName: ProductAutofillFlowPreference.fixtureSuiteName(for: secondDirectory))
        }

        ProductAutofillFlowPreference.write(.information, to: first)
        #expect(ProductAutofillFlowPreference.read(from: first) == .information)
        #expect(ProductAutofillFlowPreference.read(from: second) == .photoSelection)
        #expect(ProductAutofillFlowPreference.fixtureSuiteName(for: firstDirectory)
            != ProductAutofillFlowPreference.fixtureSuiteName(for: secondDirectory))
    }

    @Test func anInvalidSavedValueFallsBackToAWithoutChangingOtherSettings() {
        let directory = makeFixtureDirectory()
        let defaults = ProductAutofillFlowPreference.makeDefaults(fixtureDirectory: directory)
        defer { defaults.removePersistentDomain(forName: ProductAutofillFlowPreference.fixtureSuiteName(for: directory)) }

        defaults.set("previous-or-invalid-value", forKey: ProductAutofillFlowPreference.key)
        defaults.set("retained", forKey: "unrelated-setting")
        #expect(ProductAutofillFlowPreference.read(from: defaults) == .photoSelection)
        ProductAutofillFlowPreference.write(.information, to: defaults)
        #expect(defaults.string(forKey: "unrelated-setting") == "retained")
    }

    private func makeFixtureDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "FlowUITests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
