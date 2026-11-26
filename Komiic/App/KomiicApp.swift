import SwiftUI
import UIKit
import UserNotifications

@main
@MainActor
struct KomiicApp: App {
    @UIApplicationDelegateAdaptor(KomiicAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
                Color.clear
            } else {
                AppContainerView()
            }
        }
    }
}

@MainActor
private struct AppContainerView: View {
    @StateObject private var library: LibraryStore
    @StateObject private var downloads = DownloadStore()
    @StateObject private var content = AppContentStore()
    @StateObject private var settings: ReaderSettings

    init() {
        SessionCookieStore.shared.restore()
        let settings = ReaderSettings()
        _settings = StateObject(wrappedValue: settings)
        _library = StateObject(wrappedValue: LibraryStore(initialMode: settings.contentMode))
    }

    var body: some View {
        let theme = KomiicTheme(palette: settings.palette)
        RootView()
            .environmentObject(library)
            .environmentObject(downloads)
            .environmentObject(settings)
            .environmentObject(content)
            .environment(\.komiicTheme, theme)
            .tint(theme.accent)
            .preferredColorScheme(settings.theme.colorScheme)
            .task {
                downloads.applyCachePolicy(settings.cachePolicy)
                OrientationController.apply(settings.orientation)
            }
            .onChange(of: settings.orientation) { _, value in OrientationController.apply(value) }
            .onChange(of: settings.cachePolicy) { _, value in downloads.applyCachePolicy(value) }
            .onReceive(NotificationCenter.default.publisher(for: .komiicSessionDidChange).receive(on: DispatchQueue.main)) { _ in
                content.synchronizeSessionScopes()
                library.synchronizeSessionScopes()
            }
    }
}

final class KomiicAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : Self.orientationMask
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum OrientationController {
    @MainActor static func apply(_ orientation: ReaderOrientation) {
        guard UIDevice.current.userInterfaceIdiom != .pad else {
            KomiicAppDelegate.orientationMask = .all
            return
        }
        KomiicAppDelegate.orientationMask = orientation.mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation.mask)) { _ in }
        }
    }
}
