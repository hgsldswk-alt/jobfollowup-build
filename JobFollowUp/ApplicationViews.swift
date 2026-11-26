import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let dueJump: Int
    let search: () -> Void
    let add: () -> Void
    let importCSV: () -> Void

    var body: some View {
        let due = model.state?.due(on: model.today) ?? []
        let dueIDs = Set(due.map(\.id))
        let active = model.state?.ordered().filter { $0.active && !dueIDs.contains($0.id) } ?? []
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    header
                    VStack(alignment: .leading, spacing: 8) {
                        section("home.due", count: L.f("home.dueCount", due.count))
                        if due.isEmpty { empty("home.caughtUp", icon: "checkmark.circle") }
                        else { group(due, due: true) }
                    }.id("due")
                    VStack(alignment: .leading, spacing: 8) {
                        section("home.active", count: L.f("home.activeCount", active.count))
                        if active.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(L.t("home.noActive")).foregroundStyle(Paper.muted)
                                if model.jobs.isEmpty {
                                    ViewThatFits {
                                        HStack {
                                            TextAction(title: L.t("editor.add"), id: "home.emptyAdd", action: add)
                                            Spacer()
                                            TextAction(title: L.t("csv.import"), id: "home.import", action: importCSV)
                                        }
                                        VStack(alignment: .leading) {
                                            TextAction(title: L.t("editor.add"), id: "home.emptyAdd", action: add)
                                            TextAction(title: L.t("csv.import"), id: "home.import", action: importCSV)
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).paperCard()
                        } else { group(active, due: false) }
                    }
                    if let state = model.state, !state.trialNoticeSeen, model.hasPro, !state.entitlement.purchasedPro {
                        trialNotice(state)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 20)
            }
            .onChange(of: dueJump) { _, _ in reader.scrollTo("due", anchor: .top) }
            .onAppear { if dueJump > 0 { reader.scrollTo("due", anchor: .top) } }
        }
        .background(Paper.background)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) { heading; Spacer(minLength: 6); actions }
            VStack(alignment: .leading, spacing: 8) { heading; actions }
        }.accessibilitySortPriority(2)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L.t("tab.applications")).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(model.now.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.subheadline).foregroundStyle(Paper.muted)
        }
    }

    private var actions: some View {
        HStack(spacing: 7) {
            Button(action: search) {
                Image(systemName: "magnifyingglass").font(.headline).frame(width: 44, height: 44)
                    .background(Paper.card, in: RoundedRectangle(cornerRadius: 11)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(L.t("action.search")).testID("home.search")
            Button(action: add) {
                Label(L.t("action.add"), systemImage: "plus").font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44).padding(.horizontal, 12)
                    .foregroundStyle(.white).background(Paper.green, in: RoundedRectangle(cornerRadius: 11))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).testID("home.add")
        }.foregroundStyle(Paper.green)
    }

    private func section(_ key: String, count: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L.t(key)).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Spacer()
            Text(count).font(.caption).foregroundStyle(Paper.muted)
        }
    }

    private func empty(_ key: String, icon: String) -> some View {
        Label(L.t(key), systemImage: icon).foregroundStyle(Paper.muted)
            .frame(maxWidth: .infinity, alignment: .leading).paperCard()
    }

    private func group(_ jobs: [Application], due: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(jobs) { job in
                if job.id != jobs.first?.id { Rectangle().fill(Paper.border).frame(height: 1).accessibilityHidden(true) }
                row(job, due: due)
            }
        }
        .background(Paper.card)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15).strokeBorder(Paper.border).allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if due {
                Rectangle().fill(Paper.amber).frame(height: 3).padding(.horizontal, 12).allowsHitTesting(false)
            }
        }
    }

    private func row(_ job: Application, due: Bool) -> some View {
        VStack(alignment: .leading, spacing: due ? 2 : 0) {
            HStack(spacing: 8) {
                NavigationLink(value: job.id) {
                    JobIdentity(job: job, subtitle: due ? nil : job.appliedLabel)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).testID("home.job." + job.company)
                StatusControl(job: job, id: "home.status." + job.company)
            }
            if due, let day = job.due {
                HStack {
                    Label(day == model.today ? L.t("home.dueToday") : L.f("home.dueDate", day.label), systemImage: "clock")
                        .font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 6)
                        .foregroundStyle(Paper.amberText).background(Paper.amberFill, in: Capsule())
                    Spacer(minLength: 5)
                    TextAction(title: L.t("action.log"), id: "home.log." + job.company) { model.change(job, log: true) }
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, due ? 8 : 6)
    }

    private func trialNotice(_ state: JobState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.f("pay.until", Day(state.entitlement.trialEnd).label)).font(.subheadline.bold())
            Text(L.t("pay.notice")).font(.footnote).foregroundStyle(Paper.muted)
            TextAction(title: L.t("action.gotIt"), id: "home.dismissTrial") {
                model.perform(effects: false) { $0.trialNoticeSeen = true }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).paperCard()
    }
}

struct JobIdentity: View {
    let job: Application
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(job.company).font(.headline)
            Text(job.role).font(.subheadline).foregroundStyle(Paper.muted)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Paper.muted) }
        }
    }
}

struct StatusControl: View {
    @EnvironmentObject private var model: AppModel
    @State private var options = false
    let job: Application
    let id: String
    var body: some View {
        Button { options = true } label: {
            JobTag(status: job.status, dropdown: true)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.f("status.accessibility", job.status.title))
        .testID(id)
        .confirmationDialog(L.t("status.change"), isPresented: $options, titleVisibility: .visible) {
            ForEach(JobStatus.allCases.filter { $0 != job.status }) { status in
                Button(status.title) { model.change(job, status: status) }
            }
        } message: { Text(job.company + " · " + job.role) }
    }
}

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool
    @State private var query = ""
    let close: () -> Void

    var body: some View {
        NavigationStack {
            let results = model.state.map { JobMatching.search(query, state: $0) } ?? []
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Paper.green).accessibilityHidden(true)
                        TextField(L.t("search.placeholder"), text: $query)
                            .focused($focused).submitLabel(.search).autocorrectionDisabled().testID("search.query")
                            .onSubmit { focused = false }
                        if !query.isEmpty {
                            Button { query = ""; focused = true } label: {
                                Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(L.t("action.clear")).testID("search.clear")
                        }
                    }.frame(minHeight: 32).paperCard()
                    HStack {
                        Text(L.t("search.matches")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text(L.f("search.count", results.count)).font(.caption).foregroundStyle(Paper.muted)
                    }
                    if results.isEmpty { Text(L.t("search.empty")).foregroundStyle(Paper.muted).padding(.vertical, 12) }
                    LazyVStack(spacing: 8) {
                        ForEach(results) { job in
                            NavigationLink {
                                DetailView(id: job.id)
                            } label: {
                                HStack {
                                    JobIdentity(job: job, subtitle: job.sourceLabel + " · " + job.appliedLabel)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        JobTag(status: job.status)
                                        if job.archived { Text(L.t("status.archived")).font(.caption).foregroundStyle(Paper.muted) }
                                    }
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).paperCard().testID("search.job." + job.role)
                        }
                    }
                }.padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Paper.background)
            .navigationTitle(L.t("search.title")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { TextAction(title: L.t("action.cancel"), id: "search.close", action: close) } }
            .task { try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled { focused = true } }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing = false
    @State private var scheduling = false
    @State private var dismissError: String?
    let id: UUID
    var close: (() -> Void)?

    private struct TimelineLine: Identifiable {
        let id: String
        let title: String
        let date: Date
    }

    var body: some View {
        Group {
            if let job = model.jobs.first(where: { $0.id == id }) {
                detail(job)
                    .sheet(isPresented: $editing) { EditorSheet(draft: job, original: job) { editing = false } }
                    .sheet(isPresented: $scheduling) { ScheduleSheet(job: job) }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            TextAction(title: L.t("action.edit"), id: "detail.edit") { editing = true }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            if let close { TextAction(title: L.t("action.close"), id: "detail.close", action: close) }
                        }
                    }
            } else { Text(L.t("error.changed")) }
        }
        .navigationTitle(L.t("detail.title")).navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ job: Application) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(job.company).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text(job.role).font(.title3).foregroundStyle(Paper.muted)
                StatusControl(job: job, id: "detail.status")
                VStack(alignment: .leading, spacing: 10) {
                    item("field.source", value: job.sourceLabel)
                    item("field.applied", value: job.appliedLabel)
                    HStack {
                        item("field.followUp", value: job.due?.label ?? L.t("date.none"))
                        Spacer()
                        TextAction(title: L.t("action.setDate"), id: "detail.followUp") { scheduling = true }.disabled(!job.active)
                    }
                    if job.due != nil {
                        TextAction(title: L.t("action.log"), id: "detail.log") { model.change(job, log: true) }
                    }
                    if !job.positionID.isEmpty { item("field.positionID", value: job.positionID) }
                    if !job.location.isEmpty { item("field.location", value: job.location) }
                    if !job.url.isEmpty {
                        item("field.url", value: job.url)
                        TextAction(title: L.t("action.copyLink"), id: "detail.copyLink") {
                            UIPasteboard.general.string = job.url
                            dismissError = L.t("action.copied")
                        }
                        if let dismissError { Text(dismissError).font(.caption).testID("detail.copied") }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).paperCard()
                if !job.notes.isEmpty { item("field.notes", value: job.notes).paperCard() }
                if !job.excerpt.isEmpty { item("field.excerpt", value: job.excerpt).paperCard() }
                Text(L.t("detail.timeline")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 10) {
                    if let due = job.due { timeline(L.t("event.due"), date: due.label) }
                    ForEach(history(job)) { line in
                        timeline(line.title, date: Day(line.date).label)
                    }
                    if job.applied == nil && job.events.isEmpty { Text(L.t("date.unknown")) }
                }.frame(maxWidth: .infinity, alignment: .leading).paperCard()
                TextAction(title: L.t(job.archived ? "action.restoreJob" : "action.archive"), id: "detail.archive") {
                    model.change(job, archive: !job.archived)
                }
            }.padding(16)
        }.background(Paper.background)
    }

    private func history(_ job: Application) -> [TimelineLine] {
        var lines = job.events.filter { $0.kind != .created }.map {
            TimelineLine(id: $0.id.uuidString, title: $0.title, date: $0.date)
        }
        if let applied = job.applied?.date() {
            lines.append(TimelineLine(id: "applied", title: L.t("event.sent"), date: applied))
        }
        return lines.sorted { $0.date > $1.date }
    }

    private func item(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.t(key)).font(.subheadline.weight(.semibold))
            Text(value).font(.subheadline).foregroundStyle(Paper.muted).textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }

    private func timeline(_ title: String, date: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Paper.green).accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(date).foregroundStyle(Paper.muted)
        }.font(.subheadline).accessibilityElement(children: .combine)
    }
}

struct ScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var selection: Date
    @State private var busy = false
    @State private var error: String?
    let job: Application

    init(job: Application) {
        self.job = job
        _selection = State(initialValue: job.due?.date() ?? Date())
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                DatePicker(L.t("field.followUp"), selection: $selection, displayedComponents: .date).paperCard()
                    .testID("schedule.date")
                if let error { Text(error).foregroundStyle(Paper.amberText) }
                PrimaryButton(title: L.t("action.saveDate"), id: "schedule.save") { update(Day(selection), automatic: true) }.disabled(busy)
                TextAction(title: L.t("schedule.auto"), id: "schedule.auto") { update(nil, automatic: true) }.disabled(busy)
                TextAction(title: L.t("schedule.none"), id: "schedule.none") { update(nil, automatic: false) }.disabled(busy)
                Spacer()
            }.padding(16).background(Paper.background)
                .navigationTitle(L.t("field.followUp")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    TextAction(title: L.t("action.cancel"), id: "schedule.cancel") { dismiss() }.disabled(busy)
                } }
        }
    }

    private func update(_ day: Day?, automatic: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.mutate { state in
                    guard let index = state.jobs.firstIndex(where: { $0.id == job.id }),
                          state.jobs[index].active else { throw JobError.changed }
                    state.jobs[index].follow.manualDate = day
                    state.jobs[index].follow.automatic = automatic ? nil : false
                }
                dismiss()
            } catch { self.error = message(for: error) }
        }
    }
}
