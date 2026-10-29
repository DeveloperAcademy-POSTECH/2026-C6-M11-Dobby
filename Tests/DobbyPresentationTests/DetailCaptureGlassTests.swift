// Created by mason on 10/27/26.
import SwiftUI
import XCTest
@testable import Dobby

/// The former glass surface is now solid black. Verify actual backdrop
/// occlusion and the shared photo hole rather than blur/transmission styling.
@MainActor final class DetailCaptureGlassTests: XCTestCase {
    func testSurroundingsAreOpaqueBlackInBothColorSchemes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let red = try await sample(.red, scheme: scheme)
            let blue = try await sample(.blue, scheme: scheme)
            for channel in 0..<3 {
                XCTAssertLessThan(red[channel], 0.03, "배경 영상은 검정 주변부를 투과하면 안 됩니다.")
                XCTAssertLessThan(blue[channel], 0.03)
                XCTAssertEqual(red[channel], blue[channel], accuracy: 0.02)
            }
        }
    }

    func testSharedSurroundingsKeepPhotoWindowVisibleAndOutsideBlack() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let center = try await sample(.red, scheme: scheme, showsPhotoWindow: true)
            XCTAssertGreaterThan(center[0], 0.8, "사진 영역은 검정 마스크에 가려지면 안 됩니다.")
            XCTAssertLessThan(center[1], 0.1)
            XCTAssertLessThan(center[2], 0.1)
            let outside = try await sample(.red, scheme: scheme, showsPhotoWindow: true,
                                           normalizedPoint: CGPoint(x: 0.1, y: 0.1))
            for channel in outside { XCTAssertLessThan(channel, 0.03) }
        }
    }

    private func sample(_ color: Color, scheme: ColorScheme, showsPhotoWindow: Bool = false,
                        normalizedPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)) async throws -> [Double] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let view = GeometryReader { geometry in
            color.overlay {
                if showsPhotoWindow {
                    CameraBlackSurroundings(photoRect: CGRect(x: geometry.size.width * 0.25,
                        y: geometry.size.height * 0.25, width: geometry.size.width * 0.5,
                        height: geometry.size.height * 0.5))
                } else {
                    DetailCaptureGlassBackground().frame(width: 180, height: 180)
                }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, scheme)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        // Read the actual composited opacity and photo hole after layout.
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let center = try XCTUnwrap(cgImage.cropping(to:
            CGRect(x: CGFloat(cgImage.width) * normalizedPoint.x,
                   y: CGFloat(cgImage.height) * normalizedPoint.y, width: 1, height: 1)))
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
