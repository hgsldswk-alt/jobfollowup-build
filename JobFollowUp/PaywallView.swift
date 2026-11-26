import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: StoreModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Label(L.t("pay.title"), systemImage: "tray.full.fill").font(.largeTitle.bold()).foregroundStyle(Paper.green)
                    Text(L.t("pay.once")).font(.subheadline).foregroundStyle(Paper.muted)
                    if let state = model.state {
                        Text(state.entitlement.purchasedPro ? L.t("pay.owned") : model.hasPro
                             ? L.f("pay.until", Day(state.entitlement.trialEnd).label) : L.t("pay.expired"))
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading).paperCard()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        feature("pay.unlimited", icon: "tray.full")
                        feature("pay.reminders", icon: "bell")
                        feature("pay.csv", icon: "tablecells")
                        feature("pay.widgets", icon: "rectangle.grid.1x2")
                    }.frame(maxWidth: .infinity, alignment: .leading).paperCard()
                    Text(L.t("pay.notice")).font(.footnote).foregroundStyle(Paper.muted)
                    if model.state?.entitlement.purchasedPro != true {
                        if let product = store.pro {
                            PrimaryButton(title: L.f("pay.buy", product.displayPrice), id: "paywall.buy") {
                                Task { await store.buy(product, update: model.applyPurchase) }
                            }.disabled(store.busy)
                        } else if Launch.testing {
                            PrimaryButton(title: L.f("pay.buy", L.t("pay.testPrice")), id: "paywall.buy") {}
                                .disabled(true)
                        } else {
                            TextAction(title: L.t("pay.load"), id: "paywall.load") { Task { await store.load() } }
                        }
                        if model.state?.entitlement.trialClaimedAt == nil, (model.hasPro || Launch.testFlag("-paywall")) {
                            TextAction(title: L.t("pay.claim"), id: "paywall.claim") {
                                if let trial = store.trial { Task { await store.buy(trial, update: model.applyPurchase) } }
                                else { Task { await store.load() } }
                            }.disabled(store.busy)
                        }
                    }
                    TextAction(title: L.t("pay.restore"), id: "paywall.restore") {
                        Task { await store.restore(model.applyPurchase) }
                    }.disabled(store.busy)
                    if store.busy { ProgressView() }
                    if let notice = store.notice { Text(notice).font(.footnote).foregroundStyle(Paper.muted).testID("paywall.notice") }
                }.padding(16)
            }.background(Paper.background)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    TextAction(title: L.t("action.close"), id: "paywall.close") { dismiss() }
                } }
                .task { await store.load() }
        }
    }

    private func feature(_ key: String, icon: String) -> some View {
        Label(L.t(key), systemImage: icon).font(.subheadline.weight(.semibold))
    }
}
