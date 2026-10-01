//

import SwiftUI
import SwiftData

@main
struct DobbyApp: App {
    @State private var container: ModelContainer?
    @State private var storageError: String?

    init() {
        do { _container = State(initialValue: try ProductAppStorage.makeContainer()) }
        catch { _storageError = State(initialValue: error.localizedDescription) }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                ContentView().modelContainer(container)
            } else {
                VStack(spacing: 20) {
                    ContentUnavailableView("보관함을 열지 못했어요", systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(storageError ?? "다시 시도해 주세요."))
                    Button("다시 시도") {
                        do { container = try ProductAppStorage.makeContainer(); storageError = nil }
                        catch { storageError = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                }.padding()
            }
        }
    }
}
