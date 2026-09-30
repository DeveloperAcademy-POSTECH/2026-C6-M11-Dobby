//

import AppIntents
import SwiftUI

@main
struct DobbyApp: App {
    init() {
        DobbyCopyAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(product: .demo)
        }
    }
}
