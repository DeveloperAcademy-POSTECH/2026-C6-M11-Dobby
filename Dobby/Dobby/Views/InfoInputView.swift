//
//  InfoInputView.swift
//  Dobby
//
//  Created by 오하나 on 10/1/26.
//

import SwiftData
import SwiftUI

struct InfoInputView: View {
    @Bindable var garment: Garment

    @State private var showingExport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                photoStrip
                field("제품 명", text: $garment.name,
                      placeholder: "예: 90s 나이키 자켓", lines: 1...2)
                field("설명", text: $garment.detail,
                      placeholder: "연식, 실착 사이즈, 상태를 적어주세요", lines: 5...10)
                field("브랜드", text: $garment.brand,
                      placeholder: "예: 나이키", lines: 1...1)
                sizeTable
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("제품 정보 입력")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("완료") {
                    garment.updatedAt = .now
                    showingExport = true
                }
                .fontWeight(.semibold)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        // 내보내기 화면은 자체 NavigationStack과 닫기 버튼을 갖고 있어 시트로 띄운다.
        .sheet(isPresented: $showingExport) {
            ExportView()
        }
    }

    // MARK: 제품 사진

    private var photoStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("제품 사진").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(garment.orderedPhotos) { photo in
                        thumbnail(photo)
                    }
                }
                .padding(.horizontal, 20)
            }
            // 사진이 화면 가장자리까지 이어져 보이도록 바깥 여백을 상쇄한다.
            .padding(.horizontal, -20)
        }
    }

    @ViewBuilder
    private func thumbnail(_ photo: GarmentPhoto) -> some View {
        // 파일이 사라졌을 수 있으므로 늘 대체 화면을 준비한다.
        if let image = GarmentStore.image(for: photo) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 92, height: 108)
                .clipShape(Rectangle())
        } else {
            Rectangle()
                .fill(Color(.secondarySystemBackground))
                .frame(width: 92, height: 108)
                .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
        }
    }

    // MARK: 글자 입력

    private func field(_ title: String, text: Binding<String>,
                       placeholder: String, lines: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(lines)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: 실측 사이즈

    /// 항목을 가로로 늘어놓는 표. 바지는 항목이 여덟 개라 화면을 넘기므로 가로 스크롤을 둔다.
    private var sizeTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("실측 사이즈").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(garment.orderedMeasurements.enumerated()), id: \.element.id) { index, value in
                        if index > 0 {
                            Divider().frame(height: 76)
                        }
                        SizeColumn(value: value)
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - 치수 한 칸

/// 위에 항목 이름, 아래에 값. 값을 누르면 바로 고칠 수 있다.
///
/// 목업에는 연필이 없지만 편집은 남겨 두었다. 눌러서 고치는 것이 화면을 더 늘리지 않으면서
/// 숫자가 틀렸을 때 바로 손볼 수 있는 길이기 때문이다.
private struct SizeColumn: View {
    @Bindable var value: MeasuredValue

    @State private var text: String = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(value.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.04))

            HStack(spacing: 1) {
                TextField("", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .focused($isEditing)
                    .fixedSize()
                    .monospacedDigit()
                Text("cm").font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 84)
        .onAppear { text = format(value.valueCm) }
        .onChange(of: isEditing) { _, editing in
            if !editing { commit() }
        }
    }

    /// 값을 `valueCm`에 직접 대입하지 않고 `update(to:)`를 거친다. 그래야 모델이 처음 낸
    /// 값(`autoValueCm`)이 남고, 필터용 사본도 함께 맞춰진다.
    private func commit() {
        guard let entered = Double(text.replacingOccurrences(of: ",", with: ".")),
              entered > 0 else {
            // 숫자로 읽히지 않으면 되돌린다. 빈 칸이 0cm로 저장되는 것을 막는다.
            text = format(value.valueCm)
            return
        }
        value.update(to: entered)
        text = format(value.valueCm)
    }

    private func format(_ cm: Double) -> String {
        cm == cm.rounded() ? String(Int(cm)) : String(format: "%.1f", cm)
    }
}

#Preview {
    NavigationStack {
        InfoInputView(garment: SampleData.first(in: SampleData.previewContainer.mainContext))
    }
    .modelContainer(SampleData.previewContainer)
}
