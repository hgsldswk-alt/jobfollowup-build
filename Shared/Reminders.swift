import Foundation
import UserNotifications

actor Reminders {
    static let shared = Reminders()
    static let prefix = "jobs.due."
    private var running = false
    private var dirty = false

    func reconcile() async {
        guard !Launch.testing else { return }
        dirty = true
        guard !running else { return }
        running = true
        defer { running = false }
        while dirty {
            dirty = false
            await reconcileOnce()
        }
    }

    private func reconcileOnce() async {
        let center = UNUserNotificationCenter.current()
        let permission = await center.notificationSettings()
        guard let state = try? JobStore.shared.read() else { return }
        let existing = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(Self.prefix) }
        let allowed = state.settings.reminders && [.authorized, .provisional, .ephemeral].contains(permission.authorizationStatus)
        let schedule = allowed ? Self.schedule(state, from: Date()) : []
        let desired = Set(schedule.map { Self.prefix + Day($0.date).iso })
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { !desired.contains($0) })
        let indexed = Dictionary(uniqueKeysWithValues: existing.map { ($0.identifier, $0) })
        for item in schedule {
            let id = Self.prefix + Day(item.date).iso
            let content = UNMutableNotificationContent()
            content.title = L.t("notification.title")
            content.body = L.f("notification.body", item.count)
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
            if let previous = indexed[id], let trigger = previous.trigger as? UNCalendarNotificationTrigger,
               trigger.dateComponents == components, previous.content.body == content.body,
               previous.content.title == content.title { continue }
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    static func schedule(_ state: JobState, from now: Date, calendar: Calendar = .current) -> [(date: Date, count: Int)] {
        guard state.entitlement.hasPro(at: now) else { return [] }
        let dates = state.jobs.compactMap { $0.follow.due(for: $0, calendar: calendar) }.sorted()
        guard let first = dates.first else { return [] }
        let today = Day(now, calendar: calendar)
        let start = max(today, first)
        let end = start.adding(60, calendar: calendar)
        var day = start
        var index = 0
        var results: [(date: Date, count: Int)] = []
        while day <= end && results.count < 60 {
            while index < dates.count && dates[index] <= day { index += 1 }
            if let noon = day.date(in: calendar),
               let fire = calendar.date(bySettingHour: state.settings.reminderHour, minute: state.settings.reminderMinute, second: 0, of: noon),
               fire > now, index > 0 {
                guard state.entitlement.hasPro(at: fire) else { break }
                results.append((fire, index))
            }
            let next = day.adding(1, calendar: calendar)
            guard next > day else { break }
            day = next
        }
        return results
    }
}
