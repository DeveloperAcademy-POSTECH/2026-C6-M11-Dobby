import Foundation

@main struct QuickCopyLogicChecks {
    static func main() throws {
        let fruits = ProductCopyPayload.sample(for: .fruits)
        let instagram = ProductCopyPayload.sample(for: .instagram)
        precondition(fruits.price == "56000" && fruits.description.contains("Price- 56,000\n\n"))
        precondition(!fruits.description.contains("55,000"))
        precondition(instagram.description.contains("65,000 >팔로우 시 55,000"))
        precondition(fruits.description.contains("\n\nSize 59 43 32\n"))
        precondition(fruits.description.contains("😘") && fruits.description.contains("@okaoka_vtg"))
        precondition([fruits.length, fruits.waist, fruits.thigh] == ["59", "43", "32"])
        precondition(fruits.value(for: .brand) == "LEVI'S")
        precondition(fruits.value(for: .measurements) == "총장 59 cm\n허리 단면 43 cm\n허벅지 단면 32 cm")
        let id = UUID(), now = Date()
        let session = ProductCopySession(id: id, channel: .fruits, productID: "selected-product", payload: fruits, createdAt: now)
        let restored = try JSONDecoder().decode(ProductCopySession.self, from: JSONEncoder().encode(session))
        precondition(restored.id == id && restored.productID == "selected-product")
        precondition(restored.payload == fruits && !restored.isExpired)
        let expired = ProductCopySession(id: id, channel: .fruits, productID: "selected-product", payload: fruits, createdAt: now.addingTimeInterval(-9 * 3600))
        precondition(expired.isExpired)
        precondition(session.canReuse(productID: "selected-product", payload: fruits))
        precondition(!session.canReuse(productID: "another-product", payload: fruits))
        precondition(!session.canReuse(productID: "selected-product", payload: instagram))
        precondition(!expired.canReuse(productID: "selected-product", payload: fruits))
        let diagnosticSession = ProductCopySession(
            id: id,
            channel: .fruits,
            productID: "selected-product",
            payload: fruits,
            createdAt: now,
            writeStrategy: .stringProperty,
            diagnosticToken: "A81F",
            diagnosticCondition: "메모 앱 · 앱 전환 직후"
        )
        let restoredDiagnostic = try JSONDecoder().decode(
            ProductCopySession.self,
            from: JSONEncoder().encode(diagnosticSession)
        )
        precondition(restoredDiagnostic.effectiveWriteStrategy == .stringProperty)
        precondition(restoredDiagnostic.diagnosticToken == "A81F")
        precondition(!restoredDiagnostic.canReuse(productID: "selected-product", payload: fruits))
        let diagnosticResult = CopyDiagnosticResult(
            id: UUID(),
            sessionID: id,
            field: .productName,
            executionMode: "background",
            canContinueInForeground: true,
            processName: "Dobby",
            bundleIdentifier: "com.dobby.Dobby",
            beforeChangeCount: 0,
            afterChangeCount: 1,
            readBackMatches: true,
            elapsedMilliseconds: 12,
            createdAt: now,
            writeStrategy: .stringProperty,
            diagnosticToken: "A81F",
            diagnosticCondition: "메모 앱 · 앱 전환 직후"
        )
        let restoredResult = try JSONDecoder().decode(
            CopyDiagnosticResult.self,
            from: JSONEncoder().encode(diagnosticResult)
        )
        precondition(restoredResult.writeVerified && restoredResult.diagnosticToken == "A81F")
        precondition(fruits != instagram)
        precondition(ProductCopyField(rawValue: "unknown") == nil)
        print("PASS: channel data, copy mapping, session restore, diagnostic strategy and result persistence")
    }
}
