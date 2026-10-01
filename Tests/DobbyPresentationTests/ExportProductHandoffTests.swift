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
        #expect(product.fruits.productName == garment.name)
        #expect(product.fruits.description == garment.detail)
        #expect(product.fruits.brand == garment.brand)
        #expect(product.fruits.price == "23000")
        #expect(product.copyMeasurements.map(\.id) == ["totalLength", "chestWidth"])
        #expect(product.fruits.measurements == "총장 65 cm\n가슴 단면 53.25 cm")
        #expect(product.fruits.length == "65")
        #expect(product.fruits.waist.isEmpty && product.fruits.thigh.isEmpty)
        #expect(product.instagram == product.fruits)
        garment.name = "이후 수정"
        #expect(product.name == "수정한 제품명")
    }

    @Test func emptyProductDoesNotAcquireSampleValues() {
        let garment = Garment(category: "T-shirt", group: .top)
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.name.isEmpty && product.fruits.price.isEmpty)
        #expect(product.fruits.measurements.isEmpty && product.copyMeasurements.isEmpty)
        #expect(product.fruits.length.isEmpty && product.fruits.waist.isEmpty && product.fruits.thigh.isEmpty)
        #expect(product.imageData == nil && product.displayPhotos.isEmpty)
    }

    @Test func photoOrderAndRepresentativeArePreservedWithMissingFiles() {
        let garment = Garment(category: "T-shirt", group: .top)
        let first = GarmentPhoto(fileName: "first.jpg", role: .detail, order: 0)
        let missing = GarmentPhoto(fileName: "missing.jpg", role: .detail, order: 1)
        let cover = GarmentPhoto(fileName: "cover.jpg", role: .thumbnail, order: 2)
        garment.photos = [cover, missing, first]
        let bytes = [first.id: Data([1]), cover.id: Data([2])]
        let product = ExportProduct(garment: garment, loadPhoto: { bytes[$0.id] })
        #expect(product.photoData == [Data([1]), Data([2])])
        #expect(product.imageData == Data([2]))
        let fallback = ExportProduct(garment: garment, loadPhoto: { $0.id == first.id ? Data([1]) : nil })
        #expect(fallback.imageData == Data([1]))
    }

    @Test func pantsUseAcceptedLeftMeasurementsAndKeepAllActualRows() {
        let garment = Garment(category: "Jeans", group: .pants)
        garment.measurements = [
            MeasuredValue(key: "thighWidthRight", label: "허벅지 우", displayOrder: 3, valueCm: 31.2, autoValueCm: 31.2),
            MeasuredValue(key: "waistWidth", label: "허리", displayOrder: 1, valueCm: 43.1256, autoValueCm: 42),
            MeasuredValue(key: "totalLengthLeft", label: "총장 좌", displayOrder: 0, valueCm: 102.25123, autoValueCm: 103),
            MeasuredValue(key: "thighWidthLeft", label: "허벅지 좌", displayOrder: 2, valueCm: 32.32145, autoValueCm: 30)
        ]
        let product = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(product.fruits.length == "102.25123")
        #expect(product.fruits.waist == "43.1256" && product.fruits.thigh == "32.32145")
        #expect(product.copyMeasurements.map(\.id) == ["totalLengthLeft", "waistWidth", "thighWidthLeft", "thighWidthRight"])
        garment.measurements.removeAll { $0.key == "thighWidthLeft" }
        #expect(ExportProduct(garment: garment, loadPhoto: { _ in nil }).fruits.thigh == "31.2")
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
        #expect(product.copyMeasurements.isEmpty && product.fruits.measurements.isEmpty)
        #expect(product.fruits.length.isEmpty && product.fruits.waist.isEmpty && product.fruits.thigh.isEmpty)
        garment.measurements = [
            MeasuredValue(key: "waistWidth", label: "허리", displayOrder: 0, valueCm: 44, autoValueCm: 44),
            MeasuredValue(key: "thighWidthLeft", label: "허벅지", displayOrder: 1, valueCm: 32, autoValueCm: 32)
        ]
        let top = ExportProduct(garment: garment, loadPhoto: { _ in nil })
        #expect(top.fruits.waist.isEmpty && top.fruits.thigh.isEmpty)
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
        #expect(product.photoData == [Data([1]), Data([2])])
        #expect(product.imageData == Data([1]))
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
        #expect(product.copyMeasurements[0].value == "61.25")
        #expect(product.fruits.length == "67.25123456789")
        #expect(Double(product.copyMeasurements[2].value) == tiny.valueCm)
        #expect(Double(product.copyMeasurements[3].value) == large.valueCm)
        #expect(converted.valueCm == 0.6125 * 100 && converted.autoValueCm == 0.6125 * 100)
        #expect(typed.valueCm == 67.25123456789 && !typed.isEdited)
    }
}
