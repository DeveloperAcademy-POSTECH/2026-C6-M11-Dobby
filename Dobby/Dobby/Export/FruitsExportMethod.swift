import Foundation

enum FruitsExportMethod: String, CaseIterable, Identifiable {
    case detailCopyA, dynamicIslandB
    var id: String { rawValue }
    var title: String {
        "후루츠패밀리로 내보내기 (\(self == .detailCopyA ? "A" : "B"))"
    }
}
