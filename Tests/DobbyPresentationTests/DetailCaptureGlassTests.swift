// Created by mason on 10/27/26.
import SwiftUI
import XCTest
@testable import Dobby

/// 고정 스크린샷 비교 대신 배경색 투과 여부를 넓은 허용 범위로 검증한다.
@MainActor final class DetailCaptureGlassTests: XCTestCase {
    func testGlassTransmitsBackdropInBothColorSchemes() async throws {
        try XCTSkipIf(UIAccessibility.isReduceTransparencyEnabled, "투명도 줄이기가 꺼진 환경에서 실행합니다.")
        for scheme in [ColorScheme.light, .dark] {
            let red = try await sample(.red, scheme: scheme)
            let blue = try await sample(.blue, scheme: scheme)
            XCTAssertGreaterThan(red[0] - red[2], 0.1, "붉은 배경이 글라스에 비쳐야 합니다.")
            XCTAssertGreaterThan(blue[2] - blue[0], 0.1, "푸른 배경이 글라스에 비쳐야 합니다.")
        }
    }

    func testReduceTransparencyUsesDarkOpaqueBackground() async throws {
        try XCTSkipUnless(UIAccessibility.isReduceTransparencyEnabled, "투명도 줄이기를 켠 환경에서 실행합니다.")
        for scheme in [ColorScheme.light, .dark] {
            let red = try await sample(.red, scheme: scheme)
            let blue = try await sample(.blue, scheme: scheme)
            for channel in 0..<3 {
                XCTAssertLessThan(red[channel], 0.25)
                XCTAssertEqual(red[channel], blue[channel], accuracy: 0.04)
            }
        }
    }

    private func sample(_ color: Color, scheme: ColorScheme) async throws -> [Double] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let view = color.ignoresSafeArea().overlay {
            DetailCaptureGlassBackground().frame(width: 180, height: 180)
        }
        .environment(\.colorScheme, scheme)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        // 렌더 서버가 실제 글라스 배경을 합성한 뒤 앱 내부 스냅샷을 읽는다.
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let center = try XCTUnwrap(cgImage.cropping(to:
            CGRect(x: cgImage.width / 2, y: cgImage.height / 2, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        XCTAssertTrue(rendered)
        return rgba.prefix(3).map { Double($0) / 255 }
    }
}
