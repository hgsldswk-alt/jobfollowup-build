import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var handledJump = 0
    @State private var filePicker = false
    @State private var importing: CSVImport?
    @State private var cadence = false
    @State private var widgets = false
    @State private var activity: ActivityItems?
    @State private var busy = false
    var csvJump: Int
    var consumedJump: () -> Void
    var paywall: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    heading("settings.plan")
                    VStack(alignment: .leading, spacing: 7) {
                        if let entitlement = model.state?.entitlement {
                            Text(plan(entitlement)).font(.headline)
                            Text(L.f("settings.active", model.state?.activeCount() ?? 0)).font(.subheadline).foregroundStyle(Paper.muted)
                        }
                        TextAction(title: L.t("pay.title"), id: "settings.paywall", action: paywall)
                    }.frame(maxWidth: .infinity, alignment: .leading).paperCard()
                }
                Group {
                    heading("settings.files")
                    VStack(alignment: .leading, spacing: 5) {
                        TextAction(title: L.t("csv.import"), id: "settings.import") { startImport() }
                        TextAction(title: L.t("csv.export"), id: "settings.export") { exportCSV() }
                        TextAction(title: L.t("cadence.import"), id: "settings.cadence") { cadence = true }
                    }.frame(maxWidth: .infinity, alignment: .leading).paperCard()
                }
                Group {
                    heading("settings.reminders")
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle(L.t("settings.reminderToggle"), isOn: Binding(
                            get: { model.hasPro && model.state?.settings.reminders == true && !model.remindersDenied },
                            set: { if model.hasPro { model.setReminders($0) } else { paywall() } }
                        )).testID("settings.reminders")
                        Text(L.t("settings.reminderInfo")).font(.footnote).foregroundStyle(Paper.muted)
                        if model.remindersDenied {
                            Text(L.t("settings.denied")).font(.footnote).foregroundStyle(Paper.amberText).testID("settings.denied")
                            TextAction(title: L.t("settings.system"), id: "settings.system") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                        if let settings = model.state?.settings, model.hasPro {
                            DatePicker(L.t("settings.time"), selection: Binding(get: {
                                Calendar.current.date(bySettingHour: settings.reminderHour, minute: settings.reminderMinute, second: 0, of: Date()) ?? Date()
                            }, set: { date in
                                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                                model.perform {
                                    $0.settings.reminderHour = parts.hour ?? 9
                                    $0.settings.reminderMinute = parts.minute ?? 0
                                }
                            }), displayedComponents: .hourAndMinute).testID("settings.time")
                        }
                    }.paperCard()
                }
                Group {
                    heading("widget.title")
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L.t("widget.names"), isOn: Binding(
                            get: { model.state?.settings.widgetNames ?? true },
                            set: { visible in model.perform { $0.settings.widgetNames = visible } }
                        )).testID("settings.widgetNames")
                        TextAction(title: L.t("widget.help"), id: "settings.widgetHelp") { widgets = true }
                    }.paperCard()
                }
            }.padding(16)
        }
        .background(Paper.background)
        .navigationTitle(L.t("tab.settings"))
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url): read(url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.error = JobError.badCSV.message }
            }
        }
        .sheet(item: $importing) { file in CSVPreviewView(file: file) }
        .sheet(isPresented: $cadence) { CadenceImportView() }
        .sheet(isPresented: $widgets) { WidgetGuide() }
        .sheet(item: $activity) { ActivitySheet(items: $0.items) }
        .onAppear { handleJump() }
        .onChange(of: csvJump) { _, _ in handleJump() }
        .task(id: phase) { if phase == .active { await model.refreshReminderPermission() } }
        .overlay(alignment: .topTrailing) { if busy { ProgressView().padding() } }
    }

    private func plan(_ entitlement: Entitlement) -> String {
        if entitlement.purchasedPro { return L.t("pay.owned") }
        if model.hasPro { return L.f("pay.until", Day(entitlement.trialEnd).label) }
        return L.t("pay.free")
    }

    private func heading(_ key: String) -> some View {
        Text(L.t(key)).font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }

    private func handleJump() {
        guard csvJump > 0 else { handledJump = 0; return }
        guard csvJump != handledJump else { return }
        handledJump = csvJump
        startImport()
        consumedJump()
    }

    private func startImport() {
        guard model.hasPro else { paywall(); return }
        guard !busy else { return }
        model.shareRequested = false
        if Launch.testFlag("-csv-fixture"), let raw = ProcessInfo.processInfo.environment["JF_CSV_TEXT"] {
            do { importing = try CSVImport(Data(raw.utf8)) }
            catch { model.error = message(for: error) }
        } else { filePicker = true }
    }

    private func read(_ url: URL) {
        busy = true
        Task {
            defer { busy = false }
            do {
                importing = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 32 * 1024 * 1024 else { throw JobError.badCSV }
                    return try CSVImport(Data(contentsOf: url, options: .mappedIfSafe))
                }.value
            } catch { model.error = message(for: error as? JobError ?? .badCSV) }
        }
    }

    private func exportCSV() {
        guard model.hasPro else { paywall(); return }
        guard !busy else { return }
        busy = true
        model.shareRequested = false
        Task {
            defer { busy = false }
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    let snapshot = try JobStore.shared.read()
                    guard snapshot.entitlement.hasPro(at: Date()) else { throw JobError.requiresPro }
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent("job-applications.csv")
                    try JobCSV.export(snapshot.ordered()).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    return file
                }.value
                if Launch.testing {
                    model.shareRequested = true
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                } else { activity = ActivityItems(items: [file]) }
            } catch { model.error = message(for: error) }
        }
    }
}

extension CSVImport: Identifiable {
    var id: String { headers.joined(separator: "\u{001F}") + ":\(records.count)" }
}

struct CSVPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State var file: CSVImport
    @State private var rows: [CSVPreviewRow] = []
    @State private var baseline: [Application] = []
    @State private var skips: Set<Int> = []
    @State private var corrections: [Int: Application] = [:]
    @State private var overwrite: Set<Int> = []
    @State private var repair: CSVRow?
    @State private var error: String?
    @State private var mapping = false
    @State private var reviewing = true
    @State private var busy = false
    @State private var previewVersion = 0
    @State private var work: Task<Void, Never>?
    private var count: Int { rows.filter { $0.kind == .new || ($0.kind == .conflict && overwrite.contains($0.id)) }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L.t("csv.previewInfo")).foregroundStyle(Paper.muted).font(.subheadline)
                    DisclosureGroup(isExpanded: $mapping) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(CSVField.allCases) { field in
                                Picker(field.title, selection: Binding(get: { file.mapping[field] ?? -1 }, set: {
                                    file.mapping[field] = $0 == -1 ? nil : $0
                                    corrections.removeAll()
                                    rebuild()
                                })) {
                                    Text(L.t("csv.unmapped")).tag(-1)
                                    ForEach(file.headers.indices, id: \.self) { index in
                                        Text(file.headers[index]).tag(index)
                                    }
                                }.testID("csv.mapping." + field.key)
                            }
                        }
                    } label: { Text(L.t("csv.mapping")).font(.headline) }.paperCard()
                    if !file.hasRequiredColumns { Text(L.t("csv.mapRequired")).foregroundStyle(Paper.amberText) }
                    if let error { Text(error).foregroundStyle(Paper.amberText).testID("csv.error") }
                    if reviewing { ProgressView() }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { item in row(item) }
                    }
                }.padding(16)
            }
            .background(Paper.background)
            .navigationTitle(L.t("csv.preview")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                TextAction(title: L.t("action.cancel"), id: "csv.cancel") { dismiss() }.disabled(busy)
            } }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: L.f("csv.commit", count), id: "csv.commit") { commit() }
                    .disabled(reviewing || busy || count == 0)
                    .opacity(reviewing || busy || count == 0 ? 0.55 : 1)
                    .padding(.horizontal, 16).padding(.vertical, 8).background(Paper.background)
            }
            .sheet(item: $repair) { item in
                CSVRepairView(row: item) { job in
                    corrections[item.id] = job
                    repair = nil
                    rebuild()
                }
            }
        }
        .onAppear { rebuild() }
        .onDisappear { work?.cancel() }
        .interactiveDismissDisabled(busy)
    }

    private func row(_ item: CSVPreviewRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(L.f("csv.line", item.id + 2)).font(.caption).foregroundStyle(Paper.muted)
                Spacer()
                Text(item.kind.title).font(.caption.weight(.semibold))
                    .foregroundStyle(item.kind == .invalid || item.kind == .conflict ? Paper.amberText : Paper.green)
            }
            Text([item.row.job.company, item.row.job.role].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.headline)
            if item.kind == .invalid {
                ForEach(item.row.problems, id: \.rawValue) { Text($0.title).font(.footnote) }
                if item.row.offsetError { Text(L.t("csv.problem.columns")).font(.footnote) }
                if !item.row.rawValues.isEmpty { Text(item.row.rawValues).font(.caption).foregroundStyle(Paper.muted) }
                HStack {
                    TextAction(title: L.t("csv.repair"), id: "csv.repair.\(item.id)") { repair = item.row }
                    TextAction(title: L.t("csv.skip"), id: "csv.skip.\(item.id)") { skips.insert(item.id); rebuild() }
                }
            }
            if item.kind == .conflict, let existing = item.existing {
                Text(L.f("csv.local", existing.status.title, existing.appliedLabel)).font(.footnote)
                Text(L.f("csv.incoming", item.row.job.status.title, item.row.job.appliedLabel)).font(.footnote)
                Toggle(L.t("csv.overwrite"), isOn: Binding(get: { overwrite.contains(item.id) }, set: {
                    if $0 { overwrite.insert(item.id) } else { overwrite.remove(item.id) }
                })).testID("csv.overwrite.\(item.id)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).paperCard()
    }

    private func rebuild() {
        guard let state = model.state else { return }
        let document = file
        let corrections = corrections
        let skips = skips
        overwrite.removeAll()
        work?.cancel()
        previewVersion += 1
        let generation = previewVersion
        reviewing = true
        work = Task {
            let result = await Task.detached(priority: .userInitiated) {
                document.preview(state: state, corrections: corrections, skipping: skips)
            }.value
            guard !Task.isCancelled, generation == previewVersion else { return }
            rows = result
            baseline = state.jobs
            reviewing = false
        }
    }

    private func commit() {
        let rows = rows
        let overwrite = overwrite
        let baseline = baseline
        busy = true
        Task {
            defer { busy = false }
            do {
                let count = try await model.mutate { try CSVImport.commit(rows, overwrite: overwrite, baseline: baseline, state: &$0) }
                model.banner = L.f("csv.result", count)
                dismiss()
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    model.banner = nil
                }
            } catch {
                self.error = message(for: error)
                await model.reload()
                rebuild()
            }
        }
    }
}

struct CSVRepairView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var job: Application
    let save: (Application) -> Void
    init(row: CSVRow, save: @escaping (Application) -> Void) {
        _job = State(initialValue: row.job)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L.t("field.company"), text: $job.company).paperCard().testID("repair.company")
                    TextField(L.t("field.role"), text: $job.role).paperCard().testID("repair.role")
                    Picker(L.t("field.status"), selection: $job.status) {
                        ForEach(JobStatus.allCases) { Text($0.title).tag($0) }
                    }.paperCard().testID("repair.status")
                    DateField(title: L.t("field.applied"), day: $job.applied, id: "repair.applied")
                    DateField(title: L.t("field.followUp"), day: $job.follow.manualDate, id: "repair.followUp")
                    Toggle(L.t("status.archived"), isOn: $job.archived).paperCard().testID("repair.archived")
                    PrimaryButton(title: L.t("action.save"), id: "repair.save") {
                        job.trimFields()
                        save(job)
                    }.disabled(!job.requiredFilled)
                }.padding(16)
            }.background(Paper.background)
                .navigationTitle(L.t("csv.repair")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    TextAction(title: L.t("action.cancel"), id: "repair.cancel") { dismiss() }
                } }
        }
    }
}

struct CadenceImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var input = ""
    @State private var preview: CadenceTemplate?
    @State private var error: String?
    @FocusState private var typing: Bool
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(L.t("cadence.code"), text: $input, axis: .vertical).focused($typing).font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never).paperCard().testID("cadence.input")
                    TextAction(title: L.t("action.paste"), id: "cadence.paste") {
                        input = UIPasteboard.general.string ?? ""
                    }
                    if let preview {
                        Text(L.t("cadence.info")).font(.subheadline)
                        ForEach(preview.intervals.indices, id: \.self) { index in
                            Text(L.f(index == 0 ? "cadence.first" : "cadence.next", preview.intervals[index]))
                        }
                        PrimaryButton(title: L.t("cadence.use"), id: "cadence.use") { use(preview) }
                    } else {
                        PrimaryButton(title: L.t("action.preview"), id: "cadence.preview") {
                            typing = false
                            do { preview = try CadenceTemplate.decode(input); error = nil }
                            catch { self.error = message(for: error) }
                        }
                    }
                    if let error { Text(error).foregroundStyle(Paper.amberText).testID("cadence.error") }
                }.padding(16)
            }.background(Paper.background).navigationTitle(L.t("cadence.import")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    TextAction(title: L.t("action.cancel"), id: "cadence.cancel") { dismiss() }
                } }
                .onChange(of: input) { _, _ in preview = nil; error = nil }
        }
    }

    private func use(_ cadence: CadenceTemplate) {
        Task {
            do {
                try await model.mutate { $0.settings.cadence = cadence }
                dismiss()
            } catch { self.error = message(for: error) }
        }
    }
}

struct WidgetGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L.t("widget.home")).font(.title2.bold())
                    Text(L.t("widget.homeHelp")).paperCard()
                    Text(L.t("widget.lock")).font(.title2.bold())
                    Text(L.t("widget.lockHelp")).paperCard()
                    Text(L.t("widget.proHelp")).foregroundStyle(Paper.muted)
                }.padding(16).accessibilityElement(children: .contain).testID("widget.guide")
            }.background(Paper.background).navigationTitle(L.t("widget.title")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    TextAction(title: L.t("action.close"), id: "widget.close") { dismiss() }
                } }
        }
    }
}
