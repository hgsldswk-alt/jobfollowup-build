import SwiftUI
import WidgetKit

struct DueEntry: TimelineEntry {
    let date: Date
    let active: Bool
    let count: Int
    let companies: [String]
}

struct DueProvider: TimelineProvider {
    func placeholder(in context: Context) -> DueEntry {
        DueEntry(date: Date(), active: true, count: 2, companies: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (DueEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let family = context.family
        DispatchQueue.global(qos: .userInitiated).async {
            let now = Date()
            let state = try? JobStore.shared.read(initialize: false)
            completion(entry(state: state, date: now, family: family))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DueEntry>) -> Void) {
        let family = context.family
        DispatchQueue.global(qos: .userInitiated).async {
            let now = Date()
            let calendar = Calendar.current
            let state = try? JobStore.shared.read(initialize: false)
            let today = calendar.startOfDay(for: now)
            let midnights = (1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
            var dates = [now] + midnights
            if let entitlement = state?.entitlement, !entitlement.purchasedPro, entitlement.trialEnd > now {
                dates.append(entitlement.trialEnd)
            }
            let entries = Set(dates).sorted().map { entry(state: state, date: $0, family: family) }
            completion(Timeline(entries: entries, policy: .after(midnights.last ?? now.addingTimeInterval(7200))))
        }
    }

    private func entry(state: JobState?, date: Date, family: WidgetFamily) -> DueEntry {
        guard let state, state.entitlement.hasPro(at: date) else {
            return DueEntry(date: date, active: false, count: 0, companies: [])
        }
        let jobs = state.due(on: Day(date))
        let showNames = state.settings.widgetNames && (family == .systemSmall || family == .systemMedium)
        return DueEntry(date: date, active: true, count: jobs.count,
                        companies: showNames ? jobs.prefix(family == .systemSmall ? 1 : 2).map(\.company) : [])
    }
}

struct DueWidgetView: View {
    let entry: DueEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(entry.active ? L.f("home.dueCount", entry.count) : L.t("widget.open"))
            case .accessoryCircular:
                if entry.active {
                    VStack(spacing: 1) {
                        Image(systemName: "clock").font(.caption)
                        Text(entry.count.formatted()).font(.title3.bold())
                    }.accessibilityLabel(L.f("home.dueCount", entry.count))
                } else {
                    Image(systemName: "arrow.up.right.square").accessibilityLabel(L.t("widget.open"))
                }
            default: home
            }
        }
        .containerBackground(for: .widget) {
            if family == .systemSmall || family == .systemMedium { Paper.background }
            else { Color.clear }
        }
        .widgetURL(Launch.dueURL)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(L.t("home.due"), systemImage: "clock").font(.caption.bold()).foregroundStyle(Paper.green)
            if entry.active {
                Text(L.f("home.dueCount", entry.count)).font(.title2.weight(.bold)).foregroundStyle(Paper.ink)
                ForEach(Array(entry.companies.enumerated()), id: \.offset) { _, company in
                    Text(company).font(.caption).foregroundStyle(Paper.muted).lineLimit(1).privacySensitive()
                }
                if entry.count == 0 { Text(L.t("home.caughtUp")).font(.caption).foregroundStyle(Paper.muted) }
            } else {
                Text(L.t("widget.open")).font(.headline).foregroundStyle(Paper.ink)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

@main
struct FollowUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Launch.widgetKind, provider: DueProvider()) { entry in
            DueWidgetView(entry: entry)
        }
        .configurationDisplayName(L.t("widget.title"))
        .description(L.t("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular])
    }
}
