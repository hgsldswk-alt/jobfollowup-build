import SwiftUI
import UIKit

struct ActivityItems: Identifiable {
    var id = UUID()
    let items: [Any]
}

struct ActivitySheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let file = items.compactMap { $0 as? URL }.first(where: \.isFileURL)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ProgressScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var monthOffset = 0
    @State private var monthPicker = false
    @State private var card: ProgressCard?
    @State private var copied = false

    var body: some View {
        let months = availableMonths
        let month = months.indices.contains(monthOffset) ? months[monthOffset] : (months.first ?? Date())
        let label = month.formatted(.dateTime.month(.wide).year())
        let counts = ProgressCounts.month(month, jobs: model.jobs)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L.t("tab.progress")).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    TextAction(title: label, id: "progress.month") { monthPicker = true }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { totals(counts) }
                    VStack(spacing: 8) { totals(counts) }
                }
                PrimaryButton(title: L.t("share.progress"), id: "progress.share") {
                    card = ProgressCard(month: label, counts: counts, downloadURL: Launch.storeURL)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("milestone.title")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    let firstInterview = model.state?.first(.interview)
                    let firstOffer = model.state?.first(.offer)
                    if let firstInterview { milestone(.interview, date: firstInterview) }
                    if let firstOffer { milestone(.offer, date: firstOffer) }
                    if firstInterview == nil && firstOffer == nil {
                        Text(L.t("milestone.empty")).font(.subheadline).foregroundStyle(Paper.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).paperCard()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("cadence.title")).font(.headline)
                    Text((model.state?.settings.cadence.intervals ?? [7, 7]).map { L.f("cadence.days", $0) }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(Paper.muted)
                    TextAction(title: L.t("cadence.copy"), id: "progress.cadence") {
                        do {
                            UIPasteboard.general.string = try (model.state?.settings.cadence ?? CadenceTemplate()).code()
                            copied = true
                        } catch { model.error = message(for: error) }
                    }
                    if copied { Text(L.t("action.copied")).font(.caption).testID("cadence.copied") }
                }.frame(maxWidth: .infinity, alignment: .leading).paperCard()
            }.padding(16)
        }.background(Paper.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $card) { value in SharePreview(card: value) }
            .sheet(isPresented: $monthPicker) {
                NavigationStack {
                    List(Array(months.enumerated()), id: \.offset) { index, date in
                        Button {
                            monthOffset = index
                            monthPicker = false
                        } label: {
                            Text(date.formatted(.dateTime.month(.wide).year())).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.testID("progress.month.\(index)")
                    }.navigationTitle(L.t("progress.chooseMonth")).navigationBarTitleDisplayMode(.inline)
                }
            }
    }

    private var availableMonths: [Date] {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: model.now)?.start ?? model.now
        var months = Set((0..<12).compactMap { calendar.date(byAdding: .month, value: -$0, to: start) })
        for job in model.jobs {
            if let date = job.applied?.date(), let month = calendar.dateInterval(of: .month, for: date)?.start { months.insert(month) }
            for event in job.events where event.kind == .status {
                if let month = calendar.dateInterval(of: .month, for: event.date)?.start { months.insert(month) }
            }
        }
        return months.sorted { a, b in
            if a == start { return b != start }
            if b == start { return false }
            return a > b
        }
    }

    @ViewBuilder private func totals(_ counts: ProgressCounts) -> some View {
        total("progress.applied", counts.applied)
        total("progress.interviews", counts.interviews)
        total("progress.offers", counts.offers)
    }

    private func total(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(count.formatted()).font(.system(.largeTitle, design: .rounded).bold()).foregroundStyle(Paper.green)
            Text(L.t(title)).font(.subheadline).fixedSize(horizontal: true, vertical: false)
        }.frame(maxWidth: .infinity, alignment: .leading).paperCard().accessibilityElement(children: .combine)
    }

    private func milestone(_ kind: CardMilestone, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title).font(.headline)
            Text(Day(date).label).font(.subheadline).foregroundStyle(Paper.muted)
            TextAction(title: L.t("milestone.preview"), id: "progress.milestone." + kind.rawValue) {
                card = ProgressCard(month: date.formatted(.dateTime.month(.wide).year()), counts: nil, milestone: kind,
                                    downloadURL: Launch.storeURL)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).paperCard()
    }
}

struct SharePreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bytes: Data?
    @State private var image: UIImage?
    @State private var activity: ActivityItems?
    @State private var requested = false
    @State private var copied = false
    @State private var error: String?
    let card: ProgressCard

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel(card.heading + " · " + card.caption).testID("share.preview")
                    } else if error != nil {
                        TextAction(title: L.t("action.retry"), id: "share.retry") { Task { await render() } }
                    } else { ProgressView().frame(maxWidth: .infinity, minHeight: 100) }
                    if let error { Text(error).foregroundStyle(Paper.amberText) }
                    Text(L.t("share.privacy")).font(.footnote).foregroundStyle(Paper.muted)
                    Text(ProgressCard.topics).font(.subheadline).textSelection(.enabled)
                    TextAction(title: L.t("share.copy"), id: "share.copy") {
                        UIPasteboard.general.string = card.caption
                        copied = true
                    }
                    if copied { Text(L.t("action.copied")).font(.caption).testID("share.copied") }
                    if requested { Text(L.t("share.requested")).font(.caption).testID("share.requested") }
                }.padding(16)
            }.background(Paper.background)
                .navigationTitle(L.t("share.progress")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    TextAction(title: L.t("action.close"), id: "share.close") { dismiss() }
                } }
                .safeAreaInset(edge: .bottom) {
                    PrimaryButton(title: L.t("share.image"), id: "share.image") { share() }
                        .disabled(bytes == nil).opacity(bytes == nil ? 0.55 : 1)
                        .padding(.horizontal, 16).padding(.vertical, 8).background(Paper.background)
                }
                .sheet(item: $activity) { ActivitySheet(items: $0.items) }
                .task { await render() }
        }
    }

    private func render() async {
        error = nil
        let card = card
        do {
            let rendered = try await Task.detached(priority: .userInitiated) { try card.png() }.value
            bytes = rendered
            image = UIImage(data: rendered)
        } catch { self.error = message(for: error) }
    }

    private func share() {
        guard let bytes else { return }
        error = nil
        if Launch.testing { requested = true; return }
        Task {
            do {
                let file = try await Task.detached {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("follow-ups.png")
                    try bytes.write(to: url, options: .atomic)
                    return url
                }.value
                activity = ActivityItems(items: [file, card.caption])
            } catch { self.error = message(for: error) }
        }
    }
}
