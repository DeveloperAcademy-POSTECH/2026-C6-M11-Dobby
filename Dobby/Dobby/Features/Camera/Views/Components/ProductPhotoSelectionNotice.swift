// Created by mason on 10/25/26.
import SwiftUI
import UIKit

/// 그리드와 확대 화면이 같은 선택 제한 안내 및 표시 시간을 사용한다.
struct ProductPhotoSelectionNotice: View {
    @Binding var requestID: UUID?
    private let message = "사진은 최대 \(ProductPhotoModel.maximumSelectionCount)개까지 선택할 수 있습니다."

    var body: some View {
        Group {
            if requestID != nil {
                Text(message)
                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .frame(maxWidth: 302, minHeight: 50)
                    .background(Color(white: 23 / 255), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("camera.selectionLimitNotice")
            }
        }
        .allowsHitTesting(false)
        .task(id: requestID) {
            guard let noticeID = requestID else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard requestID == noticeID else { return }
            requestID = nil
        }
    }
}
