import StoreKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct JobFollowUpApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notifications
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .tint(Paper.green)
        }
    }
}

final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let openDue = Notification.Name("JobFollowUp.openDue")
    static var pending = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier.hasPrefix(Reminders.prefix) else { return }
        await MainActor.run {
            Self.pending = true
            NotificationCenter.default.post(name: Self.openDue, object: nil)
        }
    }
}

struct RootView: View {
    enum Tab: Equatable { case applications, progress, settings }
    enum Sheet: String, Identifiable { case add, shared, search, paywall; var id: String { rawValue } }
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    @State private var tab = Tab.applications
    @State private var sheet: Sheet?
    @State private var path: [UUID] = []
    @State private var dueJump = 0
    @State private var csvJump = 0
    @State private var shownStartupSheet = false
    @State private var initialLoadFinished = false

    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    private var idleForReview: Bool {
        !Launch.testing && phase == .active && tab == .applications && path.isEmpty
            && sheet == nil && model.undo == nil && model.error == nil && !model.shareRequested
            && model.banner == nil && (model.state?.trialNoticeSeen == true || !model.hasPro || model.state?.entitlement.purchasedPro == true)
    }
    private var reviewReady: Bool { idleForReview && model.state?.canRequestReview(version: appVersion) == true }

    var body: some View {
        Group {
            if model.state != nil { tabs }
            else if model.error != nil {
                VStack(spacing: 15) {
                    Text(L.t("error.unavailable"))
                    PrimaryButton(title: L.t("action.retry"), id: "home.retry") { Task { await model.reload() } }
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity).background(Paper.background)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Paper.background)
            }
        }
        .foregroundStyle(Paper.ink)
        .safeAreaInset(edge: .bottom, spacing: 0) { feedback }
        .sheet(item: $sheet) { route in
            switch route {
            case .add, .shared: EditorSheet(draft: draft(for: route), shared: route == .shared) { sheet = nil }
            case .search: SearchView { sheet = nil }
            case .paywall: PaywallView(store: model.purchases)
            }
        }
        .alert(L.t("error.title"), isPresented: Binding(get: { model.error != nil && model.state != nil },
                                                       set: { if !$0 { model.error = nil } })) {
            Button(L.t("action.ok"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .task {
            await model.start()
            initialLoadFinished = true
            if NotificationDelegate.pending { openDue() }
            guard !shownStartupSheet else { return }
            shownStartupSheet = true
            if Launch.testFlag("-paywall") { sheet = .paywall }
            else if Launch.testFlag("-shared") { sheet = .shared }
        }
        .onChange(of: phase) { _, value in
            if value == .active && initialLoadFinished {
                Task {
                    await model.reload()
                    await model.purchases.syncEntitlements(model.applyPurchase)
                }
            }
        }
        .onOpenURL { if $0.scheme == Launch.dueURL.scheme && $0.host == Launch.dueURL.host { openDue() } }
        .onReceive(NotificationCenter.default.publisher(for: NotificationDelegate.openDue)) { _ in openDue() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task { await model.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            Task { await model.reload() }
        }
        .task(id: reviewReady) {
            guard reviewReady else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, reviewReady else { return }
            if await model.consumeReview(version: appVersion), idleForReview { requestReview() }
        }
    }

    private var tabs: some View {
        Group {
            switch tab {
            case .applications:
                NavigationStack(path: $path) {
                    HomeView(dueJump: dueJump, search: { sheet = .search }, add: { sheet = .add }) {
                        tab = .settings
                        csvJump += 1
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: UUID.self) { DetailView(id: $0) }
                }
            case .progress: NavigationStack { ProgressScreen() }
            case .settings:
                NavigationStack {
                    SettingsView(csvJump: csvJump, consumedJump: { csvJump = 0 }) { sheet = .paywall }
                }
            }
        }
        .contentMargins(.bottom, tab != .applications || path.isEmpty ? 64 : 0, for: .scrollContent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if tab != .applications || path.isEmpty {
                HStack(spacing: 3) {
                    tabButton(.applications, name: "tab.applications", icon: "tray")
                    tabButton(.progress, name: "tab.progress", icon: "chart.bar.xaxis")
                    tabButton(.settings, name: "tab.settings", icon: "gearshape")
                }
                .padding(.horizontal, 8).padding(.top, 4).background(Paper.card)
                .overlay(alignment: .top) { Rectangle().fill(Paper.border).frame(height: 1).allowsHitTesting(false) }
            }
        }
        .onChange(of: tab) { _, _ in model.shareRequested = false }
    }

    private func tabButton(_ destination: Tab, name: String, icon: String) -> some View {
        Button { tab = destination } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.body).accessibilityHidden(true)
                Text(L.t(name)).font(.caption.weight(tab == destination ? .semibold : .regular)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(tab == destination ? Paper.green : Paper.muted)
            .accessibilityAddTraits(tab == destination ? [.isSelected] : []).testID(name)
    }

    @ViewBuilder private var feedback: some View {
        if model.shareRequested {
            Text(L.t("share.requested")).font(.footnote).padding(8).testID("share.requested")
        } else if let banner = model.banner {
            Text(banner).font(.footnote).frame(maxWidth: .infinity).padding(8).background(Paper.greenFill)
                .testID("app.banner")
        } else if model.undo != nil {
            HStack {
                Text(L.t("undo.confirmed")).font(.footnote)
                Spacer()
                TextAction(title: L.t("action.undo"), id: "app.undo") { model.undoLast() }
            }.padding(.horizontal, 16).background(Paper.greenFill)
        }
    }

    private func draft(for route: Sheet) -> Application {
        guard route == .shared else { return Application() }
        let env = ProcessInfo.processInfo.environment
        return JobShareParser.parse(ShareInput(url: env["JF_SHARE_URL"] ?? "", title: env["JF_SHARE_TITLE"] ?? "",
                                              text: env["JF_SHARE_TEXT"] ?? ""))
    }

    private func openDue() {
        NotificationDelegate.pending = false
        sheet = nil
        tab = .applications
        path.removeAll()
        dueJump += 1
    }
}

struct EditorSheet: View {
    @EnvironmentObject private var model: AppModel
    let draft: Application
    var original: Application?
    var shared = false
    var done: () -> Void

    var body: some View {
        JobEditor(job: draft, editing: original, shared: shared, available: model.jobs,
                  cancel: done, inspect: { _ in }, detail: { id in AnyView(DetailView(id: id).environmentObject(model)) }) { draft, separate in
            do {
                if Launch.testFlag("-save-error") { throw JobError.unavailable }
                try await model.mutate { try JobStore.save(draft, into: &$0, separate: separate, expected: original) }
                done()
            } catch {
                await model.reload()
                throw error
            }
        }
    }
}
