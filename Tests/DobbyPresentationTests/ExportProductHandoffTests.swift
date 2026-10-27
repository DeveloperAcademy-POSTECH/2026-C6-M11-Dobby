//
//  ExportProductHandoffTests.swift
//  DobbyPresentationTests
//
//  Created by mason on 10/1/26.
//

import Foundation
import Testing
@testable import Dobby

@MainActor
struct ExportProductHandoffTests {
    @Test func editedProductPreservesIdentityAndMeasurementOrder() {
        let garment = Garment(category: "T-shirt", group: .top, name: "수정한 제품명",
                              brand: "브랜드", detail: "입력한 설명", price: 23000)
        garment.measurements = [
            MeasuredValue(key: "chestWidth", label: "가슴 단면", displayOrder: 1, valueCm: 53.25, autoValueCm: 50),
            MeasuredValue(key: "totalLength", label: "총장", displayOrder: 0, valueCm: 65, autoValueCm: 64)
        ]
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.id == garment.id.uuidString)
        #expect(product.marketplacePayload.productName == garment.name)
        #expect(product.marketplacePayload.description == garment.detail)
        #expect(product.marketplacePayload.brand == garment.brand)
        #expect(product.marketplacePayload.price == "23000")
        #expect(product.exportMeasurements.map(\.id) == ["totalLength", "chestWidth"])
        #expect(product.marketplacePayload.measurements == "총장 65 cm\n가슴 단면 53.25 cm")
        #expect(product.marketplacePayload.length == "65")
        #expect(product.marketplacePayload.waist.isEmpty && product.marketplacePayload.thigh.isEmpty)
        #expect(product.instagramPayload.measurements == "총장 65cm\n가슴 단면 53.2cm")
        garment.name = "이후 수정"
        #expect(product.name == "수정한 제품명")
    }

    @Test func emptyProductDoesNotAcquireSampleValues() {
        let garment = Garment(category: "T-shirt", group: .top)
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.name.isEmpty && product.marketplacePayload.price.isEmpty)
        #expect(product.marketplacePayload.measurements.isEmpty && product.exportMeasurements.isEmpty)
        #expect(product.marketplacePayload.length.isEmpty && product.marketplacePayload.waist.isEmpty && product.marketplacePayload.thigh.isEmpty)
        #expect(product.thumbnailData == nil && product.exportPhotos.isEmpty)
    }

    @Test func currentLiDARBottomExportsAndCopiesFiveAcceptedMeasurementsInPresentationOrder() {
        let garment = Garment(category: "바지", group: .pants)
        garment.sourceMeasurementID = UUID()
        let values: [(String, Double)] = [
            ("hemWidthLeft", 21.125), ("thighWidthRight", 32.1256), ("inseamRight", 76),
            ("waistWidth", 43.25), ("frontRise", 28.5), ("totalLengthLeft", 102.25)
        ]
        garment.measurements = values.enumerated().map { index, entry in
            let value = MeasuredValue(key: entry.0, label: "원본 표기", displayOrder: index,
                                      valueCm: entry.1, autoValueCm: entry.1 - 1)
            value.garment = garment
            return value
        }
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.exportMeasurements.map(\.id) == [
            "totalLengthLeft", "waistWidth", "frontRise", "thighWidthRight", "hemWidthLeft"
        ])
        #expect(product.exportMeasurements.map(\.title) == ["총장", "허리", "밑위", "허벅지", "밑단"])
        #expect(product.marketplacePayload.thigh == "32.1256")
        #expect(product.marketplacePayload.measurements == "총장 102.25 cm\n허리 43.25 cm\n밑위 28.5 cm\n허벅지 32.1256 cm\n밑단 21.125 cm")
        #expect(product.instagramPayload == product.marketplacePayload)
        #expect(garment.measurements.count == 6)
        #expect(garment.measurement("thighWidthRight")?.label == "원본 표기")
        #expect(abs((garment.measurement("thighWidthRight")?.autoValueCm ?? .nan) - 31.1256) < 1e-10)
        garment.measurement("thighWidthRight")?.update(to: 33.75)
        let edited = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(edited.marketplacePayload.thigh == "33.75")
        #expect(edited.exportMeasurements.first { $0.id == "thighWidthRight" }?.value == "33.75")
        #expect(product.marketplacePayload.thigh == "32.1256", "An existing copy snapshot keeps its accepted value")
    }

    @Test func failedOrLegacyLiDARThighNeverAddsAnExportPlaceholderOrOtherSide() {
        let garment = Garment(category: "바지", group: .pants)
        garment.sourceMeasurementID = UUID()
        let values: [(String, Double)] = [
            ("totalLengthLeft", 102), ("waistWidth", 43), ("frontRise", 28),
            ("thighWidthRight", 0), ("thighWidthLeft", 99), ("hemWidthLeft", 22)
        ]
        garment.measurements = values.enumerated().map { index, entry in
            let value = MeasuredValue(key: entry.0, label: "원본 표기", displayOrder: index,
                                      valueCm: entry.1, autoValueCm: nil)
            value.garment = garment
            return value
        }
        let failed = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(garment.visibleMeasurements.count == 5)
        #expect(failed.exportMeasurements.map(\.title) == ["총장", "허리", "밑위", "밑단"])
        #expect(failed.marketplacePayload.thigh.isEmpty)
        #expect(!failed.marketplacePayload.measurements.contains("허벅지"))
        garment.measurements.removeAll { $0.key == "thighWidthRight" || $0.key == "thighWidthLeft" }
        let legacy = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(garment.visibleMeasurements.count == 4)
        #expect(legacy.exportMeasurements.map(\.id) == failed.exportMeasurements.map(\.id))
        #expect(legacy.marketplacePayload.thigh.isEmpty)
    }

    @Test func photoOrderAndRepresentativeArePreservedWithMissingFiles() {
        let garment = Garment(category: "T-shirt", group: .top)
        let first = GarmentPhoto(fileName: "first.jpg", role: .detail, order: 0)
        let missing = GarmentPhoto(fileName: "missing.jpg", role: .detail, order: 1)
        let cover = GarmentPhoto(fileName: "cover.jpg", role: .thumbnail, order: 2)
        garment.photos = [cover, missing, first]
        let bytes = [first.id: Data([1]), cover.id: Data([2])]
        let product = ExportProduct(garment: garment, loadPhoto: { bytes[$0.id] })
        #expect(product.photos == [Data([1]), Data([2])])
        #expect(product.thumbnailData == Data([2]))
        let fallback = ExportProduct(garment: garment, loadPhoto: { $0.id == first.id ? Data([1]) : nil })
        #expect(fallback.thumbnailData == Data([1]))
    }

    @Test func pantsUseOneAcceptedSideAndPreserveOriginalRows() {
        let garment = Garment(category: "Jeans", group: .pants)
        garment.measurements = [
            MeasuredValue(key: "thighWidthRight", label: "허벅지 우", displayOrder: 3, valueCm: 31.2, autoValueCm: 31.2),
            MeasuredValue(key: "waistWidth", label: "허리", displayOrder: 1, valueCm: 43.1256, autoValueCm: 42),
            MeasuredValue(key: "totalLengthLeft", label: "총장 좌", displayOrder: 0, valueCm: 102.25123, autoValueCm: 103),
            MeasuredValue(key: "thighWidthLeft", label: "허벅지 좌", displayOrder: 2, valueCm: 32.32145, autoValueCm: 30)
        ]
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.marketplacePayload.length == "102.25123")
        #expect(product.marketplacePayload.waist == "43.1256" && product.marketplacePayload.thigh == "32.32145")
        #expect(product.exportMeasurements.map(\.id) == ["totalLengthLeft", "waistWidth", "thighWidthLeft"])
        #expect(product.exportMeasurements.map(\.title) == ["총장", "허리", "허벅지 단면"])
        #expect(garment.orderedMeasurements.count == 4)
        #expect(garment.measurement("thighWidthRight")?.valueCm == 31.2)
        #expect(garment.measurement("thighWidthLeft")?.label == "허벅지 좌")
        garment.measurements.removeAll { $0.key == "thighWidthLeft" }
        let fallback = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(fallback.marketplacePayload.thigh == "31.2")
        #expect(fallback.exportMeasurements.map(\.id) == ["totalLengthLeft", "waistWidth", "thighWidthRight"])
        #expect(fallback.exportMeasurements.last?.title == "허벅지 단면")
    }

    @Test func topExportShowsOneSleeveWithoutChangingEitherStoredObservation() {
        let garment = Garment(category: "Jacket", group: .top)
        let definitions: [(String, String, Double)] = [
            ("shoulderWidth", "어깨", 45.1256),
            ("chestWidth", "가슴", 55.25123),
            ("hemWidth", "밑단", 51.25),
            ("sleeveLengthLeft", "왼쪽 소매길이(직선)", 62.25123456789),
            ("sleeveLengthRight", "오른쪽 소매길이(직선)", 63.875),
            ("totalLength", "총장", 68.25123)
        ]
        garment.measurements = definitions.enumerated().map { index, definition in
            MeasuredValue(key: definition.0, label: definition.1, displayOrder: index,
                          valueCm: definition.2, autoValueCm: definition.2)
        }
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.exportMeasurements.map(\.id) == ["shoulderWidth", "chestWidth", "hemWidth",
                                                    "sleeveLengthLeft", "totalLength"])
        #expect(product.exportMeasurements.first { $0.id == "sleeveLengthLeft" }?.title == "소매길이")
        #expect(product.exportMeasurements.first { $0.id == "sleeveLengthLeft" }?.value == "62.25123456789")
        #expect(!product.marketplacePayload.measurements.contains("오른쪽") && !product.marketplacePayload.measurements.contains("왼쪽"))
        #expect(product.instagramPayload.measurements == [
            "어깨 45.1cm", "가슴 55.2cm", "밑단 51.2cm", "소매길이 62.2cm", "총장 68.2cm"
        ].joined(separator: "\n"))
        #expect(garment.orderedMeasurements.count == 6 && garment.visibleMeasurements.count == 5)
        for (value, definition) in zip(garment.orderedMeasurements, definitions) {
            #expect(value.label == definition.1)
            #expect(value.valueCm == definition.2 && value.autoValueCm == definition.2)
            #expect(!value.isEdited)
        }
    }

    @Test func bottomExportShowsFiveActualMeasurementsAndKeepsAllEightOriginals() {
        let garment = Garment(category: "Jeans", group: .pants)
        let definitions: [(String, String, Double)] = [
            ("waistWidth", "허리", 43.1256), ("frontRise", "밑위", 31.25),
            ("totalLengthLeft", "왼쪽 총장", 102.25123), ("hemWidthLeft", "왼쪽 밑단", 21.125),
            ("inseamLeft", "왼쪽 인심", 72.5123), ("totalLengthRight", "오른쪽 총장", 103.75),
            ("hemWidthRight", "오른쪽 밑단", 22.75), ("inseamRight", "오른쪽 인심", 73.125)
        ]
        garment.measurements = definitions.enumerated().map { index, definition in
            MeasuredValue(key: definition.0, label: definition.1, displayOrder: index,
                          valueCm: definition.2, autoValueCm: definition.2)
        }
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.exportMeasurements.map(\.id) == ["waistWidth", "frontRise", "totalLengthLeft",
                                                    "hemWidthLeft", "inseamLeft"])
        #expect(product.exportMeasurements.map(\.title) == ["허리", "밑위", "총장", "밑단 단면", "인심(직선)"])
        #expect(product.marketplacePayload.length == "102.25123" && product.marketplacePayload.waist == "43.1256")
        #expect(product.marketplacePayload.thigh.isEmpty)
        #expect(garment.orderedMeasurements.count == 8 && garment.visibleMeasurements.count == 5)
        #expect(garment.orderedMeasurements.map(\.valueCm) == definitions.map { $0.2 })
        #expect(garment.orderedMeasurements.map(\.label) == definitions.map { $0.1 })
    }

    @Test func unusableLeftMeasurementsUseRightInExportAndFilterCopies() {
        let garment = Garment(category: "Jeans", group: .pants)
        let left = MeasuredValue(key: "totalLengthLeft", label: "왼쪽 총장", displayOrder: 0,
                                 valueCm: .nan, autoValueCm: 103)
        let right = MeasuredValue(key: "totalLengthRight", label: "오른쪽 총장", displayOrder: 3,
                                  valueCm: 101.25123456789, autoValueCm: 101.5)
        let leftThigh = MeasuredValue(key: "thighWidthLeft", label: "왼쪽 허벅지", displayOrder: 1,
                                      valueCm: 0, autoValueCm: 31)
        let rightThigh = MeasuredValue(key: "thighWidthRight", label: "오른쪽 허벅지", displayOrder: 2,
                                       valueCm: 32.1256, autoValueCm: 32)
        garment.measurements = [right, leftThigh, rightThigh, left]
        garment.syncFilterFields()
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.exportMeasurements.map(\.id) == ["thighWidthRight", "totalLengthRight"])
        #expect(product.exportMeasurements.map(\.title) == ["허벅지 단면", "총장"])
        #expect(product.marketplacePayload.length == "101.25123456789" && product.marketplacePayload.thigh == "32.1256")
        #expect(garment.lengthCm == right.valueCm)
        #expect(left.valueCm.isNaN && left.autoValueCm == 103 && !left.isEdited)
        #expect(leftThigh.valueCm == 0 && leftThigh.autoValueCm == 31 && !leftThigh.isEdited)
        #expect(right.label == "오른쪽 총장" && garment.orderedMeasurements.count == 4)
    }

    @Test func invalidValuesAndPantsFieldsAreNeverSubstitutedIntoTopExport() {
        let garment = Garment(category: "Jacket", group: .top)
        garment.measurements = [
            MeasuredValue(key: "totalLength", label: "총장", displayOrder: 0, valueCm: .nan, autoValueCm: 68),
            MeasuredValue(key: "chestWidth", label: "가슴", displayOrder: 1, valueCm: 0, autoValueCm: 55),
            MeasuredValue(key: "shoulderWidth", label: "어깨", displayOrder: 2, valueCm: -1, autoValueCm: 46),
            MeasuredValue(key: "sleeveLengthLeft", label: "소매", displayOrder: 3, valueCm: .infinity, autoValueCm: 60)
        ]
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.exportMeasurements.isEmpty && product.marketplacePayload.measurements.isEmpty)
        #expect(product.marketplacePayload.length.isEmpty && product.marketplacePayload.waist.isEmpty && product.marketplacePayload.thigh.isEmpty)
        garment.measurements = [
            MeasuredValue(key: "waistWidth", label: "허리", displayOrder: 0, valueCm: 44, autoValueCm: 44),
            MeasuredValue(key: "thighWidthLeft", label: "허벅지", displayOrder: 1, valueCm: 32, autoValueCm: 32)
        ]
        let top = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(top.marketplacePayload.waist.isEmpty && top.marketplacePayload.thigh.isEmpty)
    }

    @Test func unselectedMeasurementEvidenceDoesNotLeakIntoProductPhotos() {
        let garment = Garment(category: "Jacket", group: .top)
        let evidence = GarmentPhoto(fileName: "measurement.jpg", role: .thumbnail, order: 0,
                                    isMeasurementSource: true)
        evidence.isSelectedForProduct = false
        let chosen = GarmentPhoto(fileName: "chosen.jpg", role: .thumbnail, order: 1)
        chosen.isSelectedForProduct = true
        let legacy = GarmentPhoto(fileName: "legacy.jpg", role: .detail, order: 2)
        garment.photos = [legacy, chosen, evidence]
        let bytes = [evidence.id: Data([0]), chosen.id: Data([1]), legacy.id: Data([2])]
        let product = ExportProduct(garment: garment, loadPhoto: { bytes[$0.id] })
        #expect(product.photos == [Data([1]), Data([2])])
        #expect(product.thumbnailData == Data([1]))
        #expect(garment.measurementPhoto?.id == evidence.id)
    }

    @Test func centimetreConversionNoiseIsHiddenWithoutChangingStoredPrecision() {
        let garment = Garment(category: "Jacket", group: .top)
        let converted = MeasuredValue(key: "chestWidth", label: "가슴", displayOrder: 0,
            valueCm: 0.6125 * 100, autoValueCm: 0.6125 * 100)
        let typed = MeasuredValue(key: "totalLength", label: "총장", displayOrder: 1,
            valueCm: 67.25123456789, autoValueCm: 68)
        let tiny = MeasuredValue(key: "tiny", label: "작은 값", displayOrder: 2,
            valueCm: 0.00000001, autoValueCm: nil)
        let large = MeasuredValue(key: "large", label: "큰 값", displayOrder: 3,
            valueCm: 1e19, autoValueCm: nil)
        garment.measurements = [converted, typed, tiny, large]
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.exportMeasurements[0].value == "61.25")
        #expect(product.marketplacePayload.length == "67.25123456789")
        #expect(Double(product.exportMeasurements[2].value) == tiny.valueCm)
        #expect(Double(product.exportMeasurements[3].value) == large.valueCm)
        #expect(converted.valueCm == 0.6125 * 100 && converted.autoValueCm == 0.6125 * 100)
        #expect(typed.valueCm == 67.25123456789 && !typed.isEdited)
    }

    @Test func instagramMeasurementsTruncateAndOmitZeroDecimal() {
        let garment = Garment(category: "Jacket", group: .top)
        garment.measurements = [
            MeasuredValue(key: "a", label: "A", displayOrder: 0, valueCm: 45.95, autoValueCm: nil),
            MeasuredValue(key: "b", label: "B", displayOrder: 1, valueCm: 45.99, autoValueCm: nil),
            MeasuredValue(key: "c", label: "C", displayOrder: 2, valueCm: 45.01, autoValueCm: nil),
            MeasuredValue(key: "d", label: "D", displayOrder: 3, valueCm: 45, autoValueCm: nil)
        ]

        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })

        #expect(product.instagramPayload.measurements == "A 45.9cm\nB 45.9cm\nC 45cm\nD 45cm")
        #expect(garment.measurements.map(\.valueCm) == [45.95, 45.99, 45.01, 45])
    }
}
