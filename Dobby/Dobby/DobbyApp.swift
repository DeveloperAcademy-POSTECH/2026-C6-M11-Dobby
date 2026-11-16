//

import SwiftUI
import SwiftData

@main
struct DobbyApp: App {
    @State private var container: ModelContainer?
    @State private var storageError: String?
    @State private var showsLaunchSplash = true

    init() {
#if DEBUG
        if ProcessInfo.processInfo.environment["DOBBY_AI_AUTH_TOKEN"] != nil {
            ProductAutofillDevelopmentAuth.bootstrapAtLaunch()
        }
#endif
        do { _container = State(initialValue: try ProductAppStorage.makeContainer()) }
        catch { _storageError = State(initialValue: error.localizedDescription) }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                applicationContent
                    .allowsHitTesting(!showsLaunchSplash)
                    .accessibilityHidden(showsLaunchSplash)

                if showsLaunchSplash {
                    LaunchSplashView {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showsLaunchSplash = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            // The launch artwork has a light background. Restore the app's
            // existing appearance as soon as the one-time launch is complete.
            .preferredColorScheme(showsLaunchSplash ? .light : nil)
        }
    }

    @ViewBuilder
    private var applicationContent: some View {
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
