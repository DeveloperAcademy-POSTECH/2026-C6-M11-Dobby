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
}
