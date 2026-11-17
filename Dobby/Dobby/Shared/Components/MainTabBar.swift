import SwiftUI
import UIKit

enum MainTab: Hashable {
    case capture
    case library
    case settings

    var title: String {
        switch self {
        case .capture: "홈"
        case .library: "보관함"
        case .settings: "설정"
        }
    }

    // Supply only the artwork. TabView still owns the glass, hit targets,
    // VoiceOver selection state and the gesture that slides between tabs.
    func label(selected: MainTab, symbol: String) -> Image {
        let color = UIColor(resource: self == selected ? .brandNeutralBlack : .brandNeutral600)
        let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let icon = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(color)
        let caption = NSAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color
        ])
        let iconHeight: CGFloat = 28
        let canvas = CGSize(width: ceil(max(icon?.size.width ?? 0, caption.size().width)),
                            height: iconHeight + ceil(caption.size().height))
        let artwork = UIGraphicsImageRenderer(size: canvas).image { _ in
            if let icon {
                icon.draw(at: CGPoint(x: (canvas.width - icon.size.width) / 2,
                                      y: (iconHeight - icon.size.height) / 2))
            }
            caption.draw(at: CGPoint(x: (canvas.width - caption.size().width) / 2, y: iconHeight))
        }
        return Image(uiImage: artwork).renderingMode(.original)
    }
}
