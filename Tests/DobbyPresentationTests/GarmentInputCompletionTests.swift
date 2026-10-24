import Foundation
import SwiftData
import Testing
@testable import Dobby

@MainActor
struct GarmentInputCompletionTests {
    @Test func numericQualityAdvisoryDoesNotBecomeProductInputFailure() {
        let (_, length, _) = product()
        length.sourceStatusRaw = "uncertain"
        #expect(GarmentMeasurementInputText.hasUsableValue(length, drafts: [:]))
        #expect(GarmentMeasurementInputText.hasUsableValue(length, drafts: [length.id: ""]),
                "Clearing a field must not falsely claim its automatic measurement failed")
        #expect(length.sourceStatusRaw == "uncertain" && !length.isEdited)
        length.valueCm = 0
        #expect(!GarmentMeasurementInputText.hasUsableValue(length, drafts: [:]))
        #expect(GarmentMeasurementInputText.hasUsableValue(length, drafts: [length.id: "67.25"]))
        #expect(!GarmentMeasurementInputText.hasUsableValue(length, drafts: [length.id: "NaN"]))
        #expect(length.valueCm == 0 && !length.isEdited)
    }

    private func product() -> (Garment, MeasuredValue, MeasuredValue) {
        let garment = Garment(category: "Jacket", group: .top, name: "직접 입력한 자켓")
        let length = MeasuredValue(key: "totalLength", label: "총장", displayOrder: 1,
                                   valueCm: 68.12345, autoValueCm: 68.12345)
        let chest = MeasuredValue(key: "chestWidth", label: "가슴", displayOrder: 0,
                                  valueCm: 55.25, autoValueCm: 55.25)
        garment.measurements = [length, chest]
        length.garment = garment
        chest.garment = garment
        return (garment, length, chest)
    }

    @Test func doneConsumesFocusedDraftOnceAndPreservesAutomaticOriginal() throws {
        let (garment, length, chest) = product()
        var drafts = [length.id: "67.25123"]
        var saves = 0
        try GarmentInputCompletion.save(garment: garment, drafts: &drafts) { saves += 1 }
        #expect(saves == 1 && drafts.isEmpty)
        #expect(garment.informationCompletedAt != nil)
        #expect(length.valueCm == 67.2 && length.autoValueCm == 68.12345 && length.isEdited)
        #expect(chest.valueCm == 55.2 && !chest.isEdited)
        #expect(garment.lengthCm == 67.2 && garment.chestCm == 55.2)
        let export = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(export.copyMeasurements.map(\.id) == ["chestWidth", "totalLength"])
        #expect(export.fruits.length == "67.2")
        #expect(export.fruits.measurements == "가슴 55.2 cm\n총장 67.2 cm")
    }

    @Test func successfulSaveTruncatesFromSecondDecimalWithoutRounding() throws {
        let fixtures: [(input: String, stored: Double)] = [
            ("45.95", 45.9), ("45.99", 45.9), ("45.01", 45), ("45.0", 45)
        ]
        for fixture in fixtures {
            let (garment, length, _) = product()
            var drafts = [length.id: fixture.input]
            try GarmentInputCompletion.save(garment: garment, drafts: &drafts) {}
            #expect(length.valueCm == fixture.stored)
            #expect(length.autoValueCm == 68.12345)
        }
    }

    @Test func completedDraftKeepsTypedTextAndIgnoresLateIdenticalBindingWrites() throws {
        let fixtures = ["67.25", "67.25123"]
        for fixture in fixtures {
            let (garment, length, chest) = product()
            var input = GarmentMeasurementInputState()
            input.setText(fixture, for: length)
            try GarmentInputCompletion.save(garment: garment, drafts: &input.drafts) {}
            #expect(input.drafts.isEmpty && GarmentMeasurementInputText.format(length.valueCm) == "67")
            #expect(input.text(for: length) == fixture)
            for _ in 0..<3 {
                // TextField can write its displayed value again while keyboard
                // and navigation change. It must remain the original typed text.
                input.setText(input.text(for: length), for: length)
                #expect(input.drafts.isEmpty)
                try GarmentInputCompletion.save(garment: garment, drafts: &input.drafts) {}
            }
            #expect(length.valueCm == 67.2 && length.autoValueCm == 68.12345)
            #expect(chest.valueCm == 55.2 && !chest.isEdited)
            #expect(ExportProduct(garment: garment, loadPhoto: { _ in nil }).fruits.length == "67.2")
        }
    }

    @Test func unchangedRoundedDisplayIsNotAnEditButRetypingItIs() throws {
        let (garment, length, _) = product()
        length.valueCm = 61.2491
        length.autoValueCm = 61.2491
        var input = GarmentMeasurementInputState()
        let rounded = input.text(for: length)
        #expect(rounded == "61")
        input.setText(rounded, for: length)
        #expect(input.drafts.isEmpty)
        try GarmentInputCompletion.save(garment: garment, drafts: &input.drafts) {}
        #expect(length.valueCm == 61.2 && !length.isEdited)

        input.setText("", for: length)
        input.setText(rounded, for: length)
        #expect(input.drafts[length.id] == rounded)
        try GarmentInputCompletion.save(garment: garment, drafts: &input.drafts) {}
        #expect(length.valueCm == 61 && length.isEdited && length.autoValueCm == 61.2491)
        #expect(input.text(for: length) == rounded && input.drafts.isEmpty)
    }

    @Test func invalidDraftKeepsAllTextAndPreventsSaveWithoutPartialCommit() {
        let (garment, length, chest) = product()
        var drafts = [length.id: "67.25", chest.id: "아직 입력 중"]
        var saves = 0
        do {
            try GarmentInputCompletion.save(garment: garment, drafts: &drafts) { saves += 1 }
            Issue.record("Invalid measurement must block completion")
        } catch {
            #expect(error.localizedDescription.contains("가슴"))
        }
        #expect(saves == 0 && drafts.count == 2)
        #expect(drafts[length.id] == "67.25" && drafts[chest.id] == "아직 입력 중")
        #expect(length.valueCm == 68.12345 && chest.valueCm == 55.25)
        #expect(!length.isEdited && !chest.isEdited)
        #expect(garment.informationCompletedAt == nil)
        GarmentMeasurementInputText.commitDraft(for: chest, drafts: &drafts)
        #expect(drafts[chest.id] == "아직 입력 중")
    }

    @Test func nonfiniteNonpositiveAndEmptyInputNeverBecomesMeasurement() {
        let (garment, length, _) = product()
        for text in ["", " ", "0", "-1", "NaN", "nan", "Inf", "Infinity", "1e309"] {
            var drafts = [length.id: text]
            #expect(GarmentMeasurementInputText.parsed(text) == nil)
            do {
                try GarmentInputCompletion.save(garment: garment, drafts: &drafts) {
                    Issue.record("Invalid numeric input must not reach persistence")
                }
                Issue.record("Invalid input should throw")
            } catch {}
            #expect(drafts[length.id] == text && length.valueCm == 68.12345)
        }
        #expect(GarmentMeasurementInputText.format(.infinity).isEmpty)
        #expect(!GarmentMeasurementInputText.format(1e19).isEmpty)
    }

    @Test func failedSaveKeepsEditsForRetryAndDoesNotReparseTheDisplay() throws {
        enum PersistenceError: Error { case unavailable }
        let (garment, length, _) = product()
        garment.detail = "저장 실패 후에도 남아야 하는 설명"
        var drafts = [length.id: "67.25123"]
        do {
            try GarmentInputCompletion.save(garment: garment, drafts: &drafts) {
                throw PersistenceError.unavailable
            }
            Issue.record("Save failure should be reported")
        } catch {}
        #expect(length.valueCm == 67.25123 && length.autoValueCm == 68.12345)
        #expect(garment.detail == "저장 실패 후에도 남아야 하는 설명")
        #expect(garment.informationCompletedAt == nil)
        #expect(drafts.isEmpty)
        var retrySaves = 0
        try GarmentInputCompletion.save(garment: garment, drafts: &drafts) { retrySaves += 1 }
        #expect(retrySaves == 1 && length.valueCm == 67.2)
        #expect(garment.informationCompletedAt != nil)

        let previousCompletion = garment.informationCompletedAt
        do {
            try GarmentInputCompletion.save(garment: garment, drafts: &drafts) {
                throw PersistenceError.unavailable
            }
            Issue.record("Repeated save failure should be reported")
        } catch {}
        #expect(garment.informationCompletedAt == previousCompletion)
    }

    @Test func saveWritesAcceptedValuesAndFilterCopiesIntoSwiftData() throws {
        let container = try ModelContainer(for: Garment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let (garment, length, _) = product()
        context.insert(garment)
        var drafts = [length.id: " 61,5123 "]
        try GarmentInputCompletion.save(garment: garment, drafts: &drafts) { try context.save() }
        let reader = ModelContext(container)
        let saved = try #require(reader.fetch(FetchDescriptor<Garment>()).first)
        #expect(saved.name == "직접 입력한 자켓" && saved.lengthCm == 61.5)
        #expect(saved.measurement("totalLength")?.valueCm == 61.5)
        #expect(saved.measurement("totalLength")?.autoValueCm == 68.12345)
        #expect(saved.measurement("totalLength")?.isEdited == true)
        #expect(saved.measurement("chestWidth")?.valueCm == 55.2)
        #expect(saved.informationCompletedAt == garment.informationCompletedAt)
    }

    @Test func invalidStoredValueRequiresCorrectionBeforeNavigation() {
        let (garment, length, _) = product()
        length.valueCm = .nan
        var drafts: [UUID: String] = [:]
        do {
            try GarmentInputCompletion.save(garment: garment, drafts: &drafts) {
                Issue.record("Invalid stored value must not reach persistence")
            }
            Issue.record("Invalid stored value should require correction")
        } catch {
            #expect(error.localizedDescription.contains("총장"))
        }
    }

    @Test func rightSleeveFallbackCanBeEditedAndSavedWithoutChangingHiddenLeftEvidence() throws {
        let container = try ModelContainer(for: Garment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = Garment(category: "Jacket", group: .top)
        let left = MeasuredValue(key: "sleeveLengthLeft", label: "왼쪽 소매", displayOrder: 0,
                                 valueCm: 0, autoValueCm: 61.125)
        let right = MeasuredValue(key: "sleeveLengthRight", label: "오른쪽 소매", displayOrder: 1,
                                  valueCm: 62.25123456789, autoValueCm: 62.5)
        left.garment = garment
        right.garment = garment
        garment.measurements = [left, right]
        context.insert(garment)
        #expect(garment.visibleMeasurements.map(\.key) == ["sleeveLengthRight"])
        #expect(right.displayLabel == "소매길이")
        var drafts = [right.id: "63.5123456789"]
        try GarmentInputCompletion.save(garment: garment, drafts: &drafts) { try context.save() }
        #expect(drafts.isEmpty && garment.informationCompletedAt != nil)
        #expect(right.valueCm == 63.5 && right.autoValueCm == 62.5 && right.isEdited)
        #expect(left.valueCm == 0 && left.autoValueCm == 61.125 && !left.isEdited)
        #expect(garment.sleeveCm == right.valueCm)
        let reader = ModelContext(container)
        let saved = try #require(reader.fetch(FetchDescriptor<Garment>()).first)
        #expect(saved.orderedMeasurements.count == 2 && saved.visibleMeasurements.count == 1)
        #expect(saved.measurement("sleeveLengthLeft")?.valueCm == 0)
        #expect(saved.measurement("sleeveLengthLeft")?.label == "왼쪽 소매")
        #expect(saved.measurement("sleeveLengthRight")?.valueCm == 63.5)
        #expect(saved.measurement("sleeveLengthRight")?.label == "오른쪽 소매")
        #expect(saved.sleeveCm == 63.5)
        let exported = ExportProduct(garment: saved, loadPhoto: { _ in nil })
        #expect(exported.copyMeasurements.map(\.id) == ["sleeveLengthRight"])
        #expect(exported.copyMeasurements.first?.value == "63.5")
    }

    @Test func usableLeftCanCompleteWhileInvalidRightOriginalRemainsStored() throws {
        let garment = Garment(category: "Jeans", group: .pants)
        let left = MeasuredValue(key: "totalLengthLeft", label: "왼쪽 총장", displayOrder: 0,
                                 valueCm: 101.25123, autoValueCm: 101.5)
        let right = MeasuredValue(key: "totalLengthRight", label: "오른쪽 총장", displayOrder: 1,
                                  valueCm: -1, autoValueCm: 102)
        garment.measurements = [left, right]
        var drafts: [UUID: String] = [:]
        var saves = 0
        try GarmentInputCompletion.save(garment: garment, drafts: &drafts) { saves += 1 }
        #expect(saves == 1 && garment.informationCompletedAt != nil)
        #expect(garment.visibleMeasurements.map(\.key) == ["totalLengthLeft"])
        #expect(garment.lengthCm == left.valueCm)
        #expect(right.valueCm == -1 && right.autoValueCm == 102 && !right.isEdited)
        #expect(left.valueCm == 101.2 && !left.isEdited)
    }

    @Test func whenNeitherSideIsUsableDisplayedLeftStillRequiresCorrection() {
        let garment = Garment(category: "Jacket", group: .top)
        let left = MeasuredValue(key: "sleeveLengthLeft", label: "왼쪽 소매", displayOrder: 0,
                                 valueCm: 0, autoValueCm: 61)
        let right = MeasuredValue(key: "sleeveLengthRight", label: "오른쪽 소매", displayOrder: 1,
                                  valueCm: -1, autoValueCm: 62)
        garment.measurements = [left, right]
        #expect(garment.visibleMeasurements.map(\.key) == ["sleeveLengthLeft"])
        var drafts: [UUID: String] = [:]
        var saves = 0
        do {
            try GarmentInputCompletion.save(garment: garment, drafts: &drafts) { saves += 1 }
            Issue.record("The displayed invalid sleeve must require correction")
        } catch {
            #expect(error.localizedDescription.contains("소매길이"))
            #expect(!error.localizedDescription.contains("왼쪽"))
        }
        #expect(saves == 0 && garment.informationCompletedAt == nil)
        #expect(left.valueCm == 0 && right.valueCm == -1)
    }
}
