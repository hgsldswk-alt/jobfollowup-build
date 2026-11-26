import SwiftUI
import UIKit

struct JobEditor: View {
    enum Field: Hashable { case company, role }
    @State var job: Application
    let editing: Application?
    var shared = false
    var available: [Application]
    var cancel: () -> Void
    var inspect: (Application) -> Void
    var detail: ((UUID) -> AnyView)? = nil
    @State private var pushed: UUID?
    var save: (Application, Bool) async throws -> Void
    @FocusState private var focus: Field?
    @State private var busy = false
    @State private var error: String?
    @State private var optionalFields = false

    private var duplicate: Application? {
        guard let match = JobMatching.duplicate(of: job, in: available),
              editing.map({ JobMatching.matches($0, match) }) != true else { return nil }
        return match
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if shared {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L.t("editor.sharedFrom")).font(.subheadline.weight(.semibold))
                            if !job.source.isEmpty { Text(job.sourceLabel).font(.caption).foregroundStyle(Paper.muted) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Paper.greenFill, in: RoundedRectangle(cornerRadius: 12))
                    }
                    field("field.company", text: $job.company, id: "editor.company", focusField: .company)
                        .submitLabel(.next).onSubmit { focus = .role }
                    field("field.role", text: $job.role, id: "editor.role", focusField: .role)
                        .submitLabel(.done).onSubmit { focus = nil }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.t("field.source")).font(.subheadline.weight(.semibold))
                        TextField(L.t("source.manual"), text: Binding(get: {
                            job.source.isEmpty ? "" : job.sourceLabel
                        }, set: { value in
                            if value == L.t("source.email") { job.source = "@email" }
                            else if value == L.t("source.website") { job.source = "@website" }
                            else { job.source = value }
                        })).testID("editor.source")
                    }.paperCard()
                    DateField(title: L.t("field.applied"), day: $job.applied, id: "editor.applied")
                    if shared || editing == nil {
                        TextAction(title: L.t("action.pasteJob"), id: "editor.paste") { pasteJob() }
                    }
                    if !job.url.isEmpty || !job.excerpt.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            if !job.url.isEmpty { Text(job.url).lineLimit(2).textSelection(.enabled) }
                            if !job.excerpt.isEmpty { Text(job.excerpt).lineLimit(3) }
                        }
                        .font(.caption).foregroundStyle(Paper.muted).paperCard()
                    }
                    DisclosureGroup(isExpanded: $optionalFields) {
                        VStack(alignment: .leading, spacing: 12) {
                            supplementary("field.notes", value: $job.notes, id: "editor.notes", axis: .vertical)
                            supplementary("field.url", value: $job.url, id: "editor.url").keyboardType(.URL)
                            supplementary("field.excerpt", value: $job.excerpt, id: "editor.excerpt", axis: .vertical)
                            supplementary("field.positionID", value: $job.positionID, id: "editor.positionID")
                            supplementary("field.location", value: $job.location, id: "editor.location")
                        }.padding(.top, 10)
                    } label: { Text(L.t("editor.more")) }.paperCard()
                    if let duplicate {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L.t("duplicate.title")).font(.headline)
                            Text(L.f("duplicate.info", duplicate.appliedLabel, duplicate.status.title)).font(.subheadline)
                            TextAction(title: L.t("duplicate.view"), id: "editor.duplicate") { if detail != nil { pushed = duplicate.id } else { inspect(duplicate) } }
                        }.frame(maxWidth: .infinity, alignment: .leading).paperCard().accessibilityElement(children: .contain).testID("editor.duplicateWarning")
                    }
                }.padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Paper.background)
            .navigationTitle(L.t(editing != nil ? "editor.edit" : shared ? "editor.shared" : "editor.add"))
            .navigationDestination(item: $pushed) { id in detail?(id) ?? AnyView(EmptyView()) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    TextAction(title: L.t("action.cancel"), id: "editor.cancel", action: cancel).disabled(busy)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    if let error { Text(error).font(.footnote).foregroundStyle(Paper.amberText).testID("editor.error") }
                    PrimaryButton(title: L.t(duplicate == nil ? "action.save" : "duplicate.separate"),
                                  id: "editor.save") { submit() }
                        .disabled(!job.requiredFilled || busy)
                        .opacity(job.requiredFilled && !busy ? 1 : 0.55)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(Paper.background)
            }
        }
        .tint(Paper.green).foregroundStyle(Paper.ink).preferredColorScheme(.light)
        .task {
            guard editing == nil else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if job.company.trimmed.isEmpty { focus = .company }
            else if job.role.trimmed.isEmpty { focus = .role }
        }
        .interactiveDismissDisabled(busy)
    }

    private func field(_ key: String, text: Binding<String>, id: String, focusField: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t(key)).font(.subheadline.weight(.semibold))
            TextField(L.t(key), text: text).testID(id).focused($focus, equals: focusField)
            if shared && text.wrappedValue.trimmed.isEmpty {
                Text(L.t("editor.missing")).font(.caption).foregroundStyle(Paper.amberText)
            }
        }.paperCard()
    }

    private func supplementary(_ key: String, value: Binding<String>, id: String, axis: Axis = .horizontal) -> some View {
        TextField(L.t(key), text: value, axis: axis).testID(id)
    }

    private func submit() {
        let separate = duplicate != nil
        let draft = job
        focus = nil
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await save(draft, separate) }
            catch { self.error = message(for: error) }
        }
    }

    private func pasteJob() {
        guard let text = UIPasteboard.general.string, !text.trimmed.isEmpty else {
            error = L.t("editor.pasteEmpty")
            return
        }
        let parsed = JobShareParser.parse(ShareInput(text: String(text.prefix(100_000))))
        if job.company.trimmed.isEmpty { job.company = parsed.company }
        if job.role.trimmed.isEmpty { job.role = parsed.role }
        if job.url.isEmpty { job.url = parsed.url }
        if job.source.isEmpty { job.source = parsed.source }
        if job.location.isEmpty { job.location = parsed.location }
        if job.positionID.isEmpty { job.positionID = parsed.positionID }
        if job.excerpt.isEmpty { job.excerpt = parsed.excerpt }
        error = nil
        focus = job.company.trimmed.isEmpty ? .company : job.role.trimmed.isEmpty ? .role : nil
    }
}

struct DateField: View {
    let title: String
    @Binding var day: Day?
    let id: String
    var placeholder = L.t("date.unknown")
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if day != nil {
                DatePicker(selection: Binding(get: { day?.date() ?? Date() }, set: { day = Day($0) }),
                           displayedComponents: .date) { Text(title) }.testID(id)
                TextAction(title: L.t("action.clearDate"), id: id + ".clear") { day = nil }
            } else {
                HStack {
                    VStack(alignment: .leading) {
                        Text(title)
                        Text(placeholder).foregroundStyle(Paper.muted).font(.caption)
                    }
                    Spacer()
                    TextAction(title: L.t("action.setDate"), id: id) { day = Day(Date()) }
                }
            }
        }.paperCard()
    }
}
