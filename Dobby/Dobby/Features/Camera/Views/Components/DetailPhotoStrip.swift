// Created by mason on 10/6/26.
import SwiftUI

/// 상세 촬영 목록. 실측 사진은 보존하고 상세 사진의 삭제 요청만 상위 View로 전달한다.
struct DetailPhotoStrip: View {
    let photos: [CapturedAsset]
    let deletingPhotoID: UUID?
    let isBusy: Bool
    let onDelete: (CapturedAsset) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        thumbnail(photo, index: index).id(photo.id)
                    }
                }.padding(.horizontal, 16)
            }
            .accessibilityIdentifier("camera.detailPhotoStrip")
            .onChange(of: photos.map(\.id)) { previous, current in
                // 새 촬영만 끝으로 이동한다. 삭제할 때는 현재 위치를 유지한다.
                guard current.count > previous.count, let id = current.last,
                      !previous.contains(id) else { return }
                withAnimation { proxy.scrollTo(id, anchor: .trailing) }
            }
        }
        .frame(height: 73)
        .padding(.top, 8)
        .padding(.bottom, 15)
    }

    private func thumbnail(_ photo: CapturedAsset, index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            CameraPhotoView(source: photo.source, maximumPixelSize: 160)
                .frame(width: 36.5, height: 51)
                .contentShape(Rectangle())
                .overlay(alignment: .bottomLeading) {
                    if photo.purpose == .measurement {
                        Text("실측").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white).padding(3).background(.black.opacity(0.7))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(photo.purpose == .measurement ? "실측 사진, 삭제 불가" : "상세 사진 \(index)")
                .accessibilityIdentifier("camera.detailPhoto.\(photo.id)")
                .offset(y: 22)
            if photo.purpose == .detail {
                Button { onDelete(photo) } label: {
                    ZStack {
                        Circle().fill(Color(white: 0.12))
                        Circle().strokeBorder(.white, lineWidth: 1.2)
                        if deletingPhotoID == photo.id {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(isBusy)
                .accessibilityLabel("상세 사진 \(index) 삭제")
                .accessibilityIdentifier("camera.deletePhoto.\(photo.id)")
                .offset(x: 14.5)
            }
        }
        // 버튼 중심은 사진 우상단 (36.5, 22). 돌출된 터치 영역까지 셀에 포함한다.
        .frame(width: 58.5, height: 73, alignment: .topLeading)
    }
}
