import SwiftUI
import UIKit

struct FruitsDetailCopyView: View {
    let product: ExportProduct
    let onOpened: () -> Void
    var onEdit: () -> Void = {}
    @State private var message = ""
    @State private var feedbackTask: Task<Void, Never>?
    @State private var opening = false
    @State private var openFailed = false
    private let surface = Color("BrandNeutral100")
    private let labelColor = Color("BrandNeutral800")
    private let accent = Color("BrandOrange")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                openAppSection
                Rectangle().fill(surface).frame(height: 8)
                photos
                field("제품 명", value: product.name)
                field("설명", value: product.fruits.description, minimumHeight: 203)
                field("브랜드", value: product.fruits.brand)
                VStack(alignment: .leading, spacing: 8) {
                    Text("실측 사이즈").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(product.copyMeasurements.enumerated()), id: \.element.id) { index, measurement in
                            HStack(spacing: 0) {
                                copyControl(measurement.title, value: measurement.value)
                                    .foregroundStyle(labelColor)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, minHeight: 64)
                                    .frame(maxHeight: .infinity)
                                    .background(surface)
                                Rectangle().fill(surface).frame(width: 1)
                                Text("\(measurement.value)cm")
                                    .font(.subheadline)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, minHeight: 64)
                            }
                            if index < product.copyMeasurements.count - 1 { Divider() }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).stroke(surface, lineWidth: 1.5) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(.white)
        .foregroundStyle(Color(white: 0.1))
        .preferredColorScheme(.light)
        .overlay(alignment: .top) {
            if !message.isEmpty {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.82), in: Capsule())
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("copy.detail.feedback")
            }
        }
        .animation(.easeOut(duration: 0.2), value: message)
        .onDisappear { feedbackTask?.cancel() }
        .navigationTitle("제품 상세 페이지")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("수정", action: onEdit)
            }
        }
        .alert("후루츠패밀리를 열 수 없어요", isPresented: $openFailed) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("앱이 설치되어 있다면 홈 화면에서 직접 열어주세요.")
        }
    }

    private var openAppSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("후루츠패밀리 앱을 열어주세요")
                .font(.title2.bold())
            Text("옷 정보를 내보내기 위해서는 직접 열어주셔야해요")
                .font(.subheadline)
            Button {
                opening = true
                UIApplication.shared.open(
                    ExportChannel.fruitsFamily.destinationURL,
                    options: [.universalLinksOnly: true]
                ) { accepted in
                    Task { @MainActor in
                        opening = false
                        if accepted { onOpened() } else { openFailed = true }
                    }
                }
            } label: {
                Text("후루츠패밀리 열기")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(accent)
            .disabled(opening)
        }
    }

    private var photos: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("제품 사진").font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(product.displayPhotos.enumerated()), id: \.offset) { _, data in
                        if let photo = UIImage(data: data) {
                            Image(uiImage: photo).resizable().scaledToFill()
                                .frame(width: 77, height: 108).clipped()
                                .accessibilityLabel("제품 사진")
                        }
                    }
                    if product.displayPhotos.isEmpty {
                        Image(systemName: "tshirt")
                            .font(.largeTitle).foregroundStyle(.secondary)
                            .frame(width: 77, height: 108).background(surface)
                            .accessibilityLabel("상품 사진 없음")
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }

    private func field(_ title: String, value: String, minimumHeight: CGFloat = 52) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            copyControl(title, value: value)
            Text(value.isEmpty ? "정보 없음" : value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(minHeight: minimumHeight, alignment: .topLeading)
                .background(surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func copyControl(_ title: String, value: String) -> some View {
        Button {
            ClipboardWriter().copyText(value)
            showCopyFeedback(for: title)
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "document.on.document").foregroundStyle(accent)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .padding(.vertical, -11)
        }
        .buttonStyle(.plain)
        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("\(title) 복사")
    }

    private func showCopyFeedback(for title: String) {
        feedbackTask?.cancel()
        let subject = title == "제품 명" ? "제품명" : title
        let particle = hasFinalConsonant(subject) ? "이" : "가"
        message = "\(subject)\(particle) 복사되었습니다."
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            message = ""
        }
    }

    private func hasFinalConsonant(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last?.value,
              (0xAC00...0xD7A3).contains(scalar) else { return false }
        return (scalar - 0xAC00) % 28 != 0
    }
}
