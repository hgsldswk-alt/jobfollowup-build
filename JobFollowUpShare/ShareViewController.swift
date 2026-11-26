import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WidgetKit

final class ShareViewController: UIViewController {
    private var host: UIHostingController<ShareRoot>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let controller = UIHostingController(rootView: ShareRoot(context: extensionContext))
        host = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        controller.didMove(toParent: self)
    }
}

struct ShareRoot: View {
    let context: NSExtensionContext?
    @State private var draft: Application?
    @State private var jobs: [Application] = []
    @State private var inspected: Application?
    @State private var closed = false

    var body: some View {
        Group {
            if let draft {
                JobEditor(job: draft, editing: nil, shared: true, available: jobs,
                          cancel: cancel, inspect: { inspected = $0 }) { draft, separate in
                    let store = JobStore.shared
                    do {
                        let updated = try await Task.detached(priority: .userInitiated) {
                            try store.update { try JobStore.save(draft, into: &$0, separate: separate) }.0
                        }.value
                        jobs = updated.jobs
                        WidgetCenter.shared.reloadTimelines(ofKind: Launch.widgetKind)
                        if updated.settings.reminders && updated.entitlement.hasPro(at: Date()) {
                            await Reminders.shared.reconcile()
                        }
                        context?.completeRequest(returningItems: [], completionHandler: nil)
                    } catch {
                        if let latest = try? await Task.detached(operation: { try store.read() }).value { jobs = latest.jobs }
                        throw error
                    }
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView(L.t("share.loading"))
                    TextAction(title: L.t("action.cancel"), id: "extension.cancel", action: cancel)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Paper.background)
            }
        }
        .sheet(item: $inspected) { job in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        Text(job.company).font(.largeTitle.bold())
                        Text(job.role).font(.title3)
                        JobTag(status: job.status)
                        Text(job.sourceLabel + " · " + job.appliedLabel)
                        if !job.notes.isEmpty { Text(job.notes).textSelection(.enabled) }
                        if !job.excerpt.isEmpty { Text(job.excerpt).textSelection(.enabled) }
                        if !job.url.isEmpty { Text(job.url).textSelection(.enabled) }
                        ForEach(job.events.reversed()) { event in
                            Text(event.title + " · " + Day(event.date).label).font(.subheadline)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.background(Paper.background)
                    .navigationTitle(L.t("detail.title")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        TextAction(title: L.t("action.close"), id: "extension.closeExisting") { inspected = nil }
                    } }
            }
        }
        .tint(Paper.green).preferredColorScheme(.light)
        .task {
            guard draft == nil else { return }
            let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            let input = await SharePayload.read(items)
            let loaded = await Task.detached(priority: .userInitiated) {
                (JobShareParser.parse(input), try? JobStore.shared.read())
            }.value
            guard !closed, !Task.isCancelled else { return }
            jobs = loaded.1?.jobs ?? []
            draft = loaded.0
        }
    }

    private func cancel() {
        closed = true
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

enum SharePayload {
    static func read(_ items: [NSExtensionItem]) async -> ShareInput {
        var input = ShareInput()
        var text: [String] = []
        for item in items.prefix(8) {
            if input.title.isEmpty, let title = item.attributedTitle?.string { input.title = bounded(title) }
            if let body = item.attributedContentText?.string { append(body, to: &text) }
            for provider in (item.attachments ?? []).prefix(8) {
                if let dictionary = await load(provider, .propertyList) as? [String: Any],
                   let page = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                    input.url = preferred(input.url, page["url"])
                    input.title = preferred(input.title, page["title"])
                    input.company = preferred(input.company, page["company"])
                    input.role = preferred(input.role, page["role"])
                    input.location = preferred(input.location, page["location"])
                    input.positionID = preferred(input.positionID, page["positionID"])
                    if let body = page["text"] as? String { append(body, to: &text) }
                }
                if input.url.isEmpty {
                    let item = await load(provider, .url)
                    if let url = item as? URL { input.url = bounded(url.absoluteString) }
                    else if let url = item as? String { input.url = bounded(url) }
                }
                if let item = await load(provider, .plainText) {
                    if let body = item as? String { append(body, to: &text) }
                    else if let body = item as? NSAttributedString { append(body.string, to: &text) }
                    else if let body = item as? Data, let value = String(data: body.prefix(100_000), encoding: .utf8) { append(value, to: &text) }
                }
                if input.title.isEmpty, let title = provider.suggestedName { input.title = bounded(title) }
            }
        }
        input.text = bounded(text.joined(separator: "\n\n"))
        return input
    }

    private static func bounded(_ value: String) -> String { String(value.trimmed.prefix(100_000)) }
    private static func preferred(_ original: String, _ candidate: Any?) -> String {
        original.isEmpty ? bounded(candidate as? String ?? "") : original
    }

    private static func append(_ body: String, to items: inout [String]) {
        let text = bounded(body)
        if !text.isEmpty && !items.contains(text) { items.append(text) }
    }

    private static func load(_ provider: NSItemProvider, _ type: UTType) async -> NSSecureCoding? {
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }
}
