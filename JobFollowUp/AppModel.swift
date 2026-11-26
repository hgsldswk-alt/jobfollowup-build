import Foundation
import SwiftUI
import UserNotifications
import WidgetKit

actor JobStorageWorker {
    private var revision = 0

    func load(reset: Bool) throws -> (JobState, Int) {
        let store = JobStore.shared
        let state: JobState
        if reset {
            state = try store.update { $0 = Demo.initial() }.0
        } else { state = try store.read() }
        revision += 1
        return (state, revision)
    }

    func update<T>(_ change: (inout JobState) throws -> T) throws -> (JobState, Int, T) {
        let (state, result) = try JobStore.shared.update(change)
        revision += 1
        return (state, revision, result)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: JobState?
    @Published private(set) var now = Date()
    @Published var error: String?
    @Published var banner: String?
    @Published var undo: UndoChange?
    @Published var shareRequested = false
    @Published var remindersDenied = false
    let purchases = StoreModel()
    private let worker = JobStorageWorker()
    private var revision = 0
    private var started = false
    private var undoTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var effectsTask: Task<Void, Never>?
    var jobs: [Application] { state?.jobs ?? [] }
    var hasPro: Bool { state?.entitlement.hasPro(at: now) == true }
    var today: Day { Day(now) }

    func start() async {
        guard !started else { return }
        started = true
        await reload(reset: Launch.testFlag("-reset"))
        purchases.start(applyPurchase)
    }

    func reload(reset: Bool = false) async {
        do {
            let (loaded, revision) = try await worker.load(reset: reset)
            accept(loaded, version: revision, effects: true)
        } catch { self.error = message(for: error) }
    }

    func mutate<T>(effects: Bool = true, _ change: @escaping (inout JobState) throws -> T) async throws -> T {
        let (updated, revision, result) = try await worker.update(change)
        accept(updated, version: revision, effects: effects)
        return result
    }

    func perform(effects: Bool = true, _ change: @escaping (inout JobState) throws -> Void) {
        Task {
            do { try await mutate(effects: effects, change) }
            catch { self.error = message(for: error) }
        }
    }

    func applyPurchase(_ pro: Bool?, _ trial: Date?) async throws {
        guard pro != nil || trial != nil else { return }
        do {
            try await mutate { state in
                if let pro { state.entitlement.purchasedPro = pro }
                if let trial { state.entitlement.verifiedTrial(trial) }
            }
        } catch { throw JobError.unavailable }
    }

    func change(_ job: Application, status: JobStatus? = nil, archive: Bool? = nil, log: Bool = false) {
        Task {
            do {
                let change = try await mutate {
                    try JobStore.change(job.id, in: &$0, status: status, archive: archive, log: log)
                }
                guard let change else { return }
                undoTask?.cancel()
                undo = change
                undoTask = Task {
                    try? await Task.sleep(for: .seconds(7))
                    if !Task.isCancelled { undo = nil }
                }
            } catch { self.error = message(for: error) }
        }
    }

    func undoLast() {
        guard let change = undo else { return }
        undoTask?.cancel()
        undo = nil
        perform { try JobStore.undo(change, in: &$0) }
    }

    func setReminders(_ enabled: Bool) {
        Task {
            if enabled {
                guard hasPro else { error = JobError.requiresPro.message; return }
                if Launch.testFlag("-notifications-denied") { remindersDenied = true; return }
                do {
                    guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                        remindersDenied = true
                        return
                    }
                } catch { self.error = message(for: error); return }
            }
            remindersDenied = false
            perform { state in
                if enabled && !state.entitlement.hasPro(at: Date()) { throw JobError.requiresPro }
                state.settings.reminders = enabled
            }
        }
    }

    func refreshReminderPermission() async {
        guard !Launch.testing else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if state?.settings.reminders == true || remindersDenied {
            remindersDenied = settings.authorizationStatus == .denied
        }
    }

    func consumeReview(version: String) async -> Bool {
        do {
            return try await mutate(effects: false) { state in
                guard state.canRequestReview(version: version) else { return false }
                state.reviewedVersions.append(version)
                return true
            }
        } catch { return false }
    }

    private func accept(_ value: JobState, version: Int, effects: Bool) {
        guard revision < version else { return }
        revision = version
        now = Date()
        state = value
        expiryTask?.cancel()
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let next = value.entitlement.trialEnd > now ? min(midnight, value.entitlement.trialEnd) : midnight
        expiryTask = Task {
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            if !Task.isCancelled { await reload() }
        }
        guard effects, !Launch.testing else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: Launch.widgetKind)
        effectsTask?.cancel()
        effectsTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { await Reminders.shared.reconcile() }
        }
    }
}

enum Demo {
    static func initial() -> JobState {
        let now = Date()
        var state = JobState()
        state.trialNoticeSeen = !Launch.testFlag("-first-run")
        if Launch.testFlag("-expired") { state.entitlement.firstOpen = now.addingTimeInterval(-31 * 86_400) }
        if Launch.testFlag("-purchased") { state.entitlement.purchasedPro = true }
        if Launch.testFlag("-many") {
            state.jobs = (1...16).map { Application(company: "Test Company \($0)", role: "Test Role") }
        }
        if Launch.testFlag("-demo") {
            let today = Day(now)
            var first = Application(company: "Northline Studio", role: "Product Designer", source: "LinkedIn",
                                    applied: today.adding(-7), notes: L.t("demo.notes"))
            first.events = [StatusEvent(kind: .created, date: first.applied?.date() ?? now, status: .applied)]
            let second = Application(company: "Tala Works", role: "Research Associate", source: "Indeed",
                                     applied: today.adding(-8), status: .noReply)
            var third = Application(company: "Cedar Labs", role: "UX Researcher", source: "LinkedIn",
                                    applied: today.adding(-2), status: .interview)
            third.events = [StatusEvent(kind: .status, date: now, status: .interview)]
            let fourth = Application(company: "Bracken Health", role: "Content Designer", applied: today.adding(-2))
            let fifth = Application(company: "Meridian Press", role: "Product Designer", applied: today.adding(-1))
            let old = Application(company: "Northline Studio", role: "Brand Designer", source: "Careers",
                                  applied: today.adding(-22), status: .rejected)
            state.jobs = [first, second, third, fourth, fifth, old]
        }
        return state
    }
}
