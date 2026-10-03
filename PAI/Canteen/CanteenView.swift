import PAIKit
import QuickLook
import SwiftUI

/// The canteen's weekly mails, newest first: the order link, the menu PDFs and which meals of
/// each day are vegan or vegetarian. Swift port of `CanteenApp.tsx`; read-only, entries arrive
/// through the backend's mail webhook.
struct CanteenView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store: CanteenStore?
    @State private var previewURL: URL?

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Canteen")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($previewURL)
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = CanteenStore(api: client)
            store = newStore
            await newStore.load()
        }
    }

    @ViewBuilder
    private func content(_ store: CanteenStore) -> some View {
        if store.isLoading && store.entries.isEmpty {
            ProgressView()
        } else if let error = store.errorMessage, store.entries.isEmpty {
            VStack(spacing: 8) {
                Text(error)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await store.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else if store.entries.isEmpty {
            Text("No canteen mails yet.")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
        } else {
            List(store.entries) { entry in
                CanteenEntryRow(entry: entry) { attachment in
                    Task { await open(attachment, of: entry, store: store) }
                }
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .refreshable { await store.load() }
        }
    }

    /// Fetches the PDF with the bearer header and hands it to Quick Look as a temp file.
    private func open(_ attachment: CanteenAttachment, of entry: CanteenEntry, store: CanteenStore) async {
        guard let data = await store.loadAttachment(entryId: entry.id, attachment: attachment) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(attachment.id)-\(attachment.filename)")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        previewURL = url
    }
}

private struct CanteenEntryRow: View {
    let entry: CanteenEntry
    let onOpenPdf: (CanteenAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                Spacer()
                Text(received)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            links
            menu
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("canteen-entry-\(entry.id)")
    }

    private var links: some View {
        HStack(spacing: 8) {
            if let link = entry.link, let url = URL(string: link) {
                Link(destination: url) {
                    Label("Order form", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("canteen-order-link")
            } else {
                Text("No link")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            if entry.attachments.isEmpty {
                Text("PDFs missing")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            ForEach(entry.attachments) { attachment in
                Button {
                    onOpenPdf(attachment)
                } label: {
                    Label(CanteenDisplay.attachmentLabel(attachment), systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        switch CanteenDisplay.menuState(entry) {
        case .parsed:
            ForEach(Array((entry.menu?.days ?? []).enumerated()), id: \.offset) { _, day in
                CanteenDayView(day: day)
            }
        case .unparsed:
            Text("The menu could not be read — open the PDF instead.")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textFaint)
        case .noPdfs:
            EmptyView()
        }
    }

    private var received: String {
        guard let date = IsoTimestamp.date(from: entry.receivedAt) else { return entry.receivedAt }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    private var title: String {
        guard let span = CanteenDisplay.menuSpan(entry) else { return "Mail of \(received)" }
        return "Menu \(shortDate(span.from)) – \(shortDate(span.to))"
    }

    private func shortDate(_ iso: String) -> String {
        guard let date = Self.isoDay.date(from: iso) else { return iso }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

private struct CanteenDayView: View {
    let day: CanteenDay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CanteenDisplay.dayTitle(day))
                .font(PaiTypography.captionEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            if day.meals.isEmpty {
                Text("No vegan or vegetarian meal")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            ForEach(day.meals, id: \.number) { meal in
                CanteenMealView(meal: meal)
            }
        }
    }
}

private struct CanteenMealView: View {
    let meal: CanteenMeal

    private var accent: Color {
        meal.kind == .vegan ? PaiPalette.green500 : PaiPalette.orange500
    }

    private var kindLabel: String {
        switch meal.kind {
        case .vegan: return "Vegan"
        case .vegetarian: return "Vegetarian"
        case .unrecognized(let raw): return raw
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Meal \(meal.number) · \(kindLabel)")
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(accent)
                Spacer()
                ForEach(CanteenDisplay.flags(meal), id: \.code) { flag in
                    Text("\(flag.code) · \(flag.label)")
                        .font(PaiTypography.captionEmphasized.font)
                        .foregroundStyle(PaiPalette.orange500)
                        .padding(.horizontal, 6)
                        .background(PaiPalette.orange500.opacity(0.15), in: Capsule())
                }
            }
            Text(meal.nameDe ?? meal.nameEn ?? "")
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            if let nameEn = meal.nameEn, meal.nameDe != nil, nameEn != meal.nameDe {
                Text(nameEn)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            if !meal.ingredientsDe.isEmpty {
                Text(meal.ingredientsDe.joined(separator: " · "))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
            }
            if !meal.ingredientsEn.isEmpty {
                Text(meal.ingredientsEn.joined(separator: " · "))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.4)))
        .accessibilityIdentifier("canteen-meal-\(meal.number)")
    }
}
