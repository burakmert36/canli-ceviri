import Foundation
import SwiftUI
import UIKit

struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    var original: String
    var translation: String
    /// "Ekran", "Kamera", "Mikrofon" gibi kaynak etiketi
    let source: String
}

/// Çevrilen cümleleri telefonda saklar (Belgeler/gecmis.json, en fazla 3000 satır).
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var entries: [HistoryEntry] = []

    private let url: URL
    private var saveWork: DispatchWorkItem?
    private let maxEntries = 3000

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        url = docs.appendingPathComponent("gecmis.json")
        if let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            entries = (try? dec.decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    @discardableResult
    func add(original: String, translation: String, source: String) -> UUID {
        let e = HistoryEntry(id: UUID(), date: Date(), original: original, translation: translation, source: source)
        entries.append(e)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        scheduleSave()
        return e.id
    }

    func update(_ id: UUID, original: String, translation: String) {
        guard let i = entries.lastIndex(where: { $0.id == id }) else { return }
        guard entries[i].original != original || entries[i].translation != translation else { return }
        entries[i].original = original
        entries[i].translation = translation
        scheduleSave()
    }

    func delete(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    func exportText(_ items: [HistoryEntry]) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMM yyyy HH:mm:ss"
        return items.map { e in
            var s = "[\(f.string(from: e.date))] \(e.source)\n"
            if !e.original.isEmpty { s += e.original + "\n" }
            if !e.translation.isEmpty { s += "→ " + e.translation + "\n" }
            return s
        }.joined(separator: "\n")
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = entries
        let target = url
        let w = DispatchWorkItem {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(snapshot) {
                try? data.write(to: target, options: .atomic)
            }
        }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @EnvironmentObject private var s: AppSettings
    @State private var query = ""
    @State private var confirmClear = false
    @State private var copiedID: UUID?

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = store.entries.reversed()
        guard !q.isEmpty else { return Array(list) }
        return list.filter { $0.original.lowercased().contains(q) || $0.translation.lowercased().contains(q) }
    }

    private var days: [(day: Date, items: [HistoryEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    ContentUnavailableView {
                        Label("Henüz kayıt yok", systemImage: "text.bubble")
                    } description: {
                        Text(s.historyEnabled
                             ? "Çeviri yaptıkça her cümle ve Türkçesi burada birikir. Arayabilir, kopyalayabilir, paylaşabilirsin."
                             : "Geçmiş kaydı kapalı. Ayarlar'dan açabilirsin.")
                    }
                } else {
                    List {
                        ForEach(days, id: \.day) { group in
                            Section(group.day.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "tr_TR")))) {
                                ForEach(group.items) { e in row(e) }
                                    .onDelete { offsets in
                                        store.delete(Set(offsets.map { group.items[$0].id }))
                                    }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $query, prompt: "Geçmişte ara")
                }
            }
            .navigationTitle("Geçmiş")
            .toolbar {
                if !store.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: store.exportText(Array(filtered.reversed()))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                    }
                }
            }
            .confirmationDialog("Tüm geçmiş silinsin mi?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Hepsini sil", role: .destructive) { store.clear() }
                Button("Vazgeç", role: .cancel) {}
            }
        }
    }

    private func row(_ e: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !e.translation.isEmpty {
                Text(e.translation).font(.body)
            }
            if !e.original.isEmpty {
                Text(e.original).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(e.date.formatted(date: .omitted, time: .standard))
                Text("·")
                Text(e.source)
                if copiedID == e.id {
                    Text("· Kopyalandı").foregroundStyle(.tint)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button { copy(e.translation, e.id) } label: { Label("Çeviriyi kopyala", systemImage: "doc.on.doc") }
            Button { copy(e.original, e.id) } label: { Label("Orijinali kopyala", systemImage: "doc.on.doc") }
            Button { copy("\(e.original)\n→ \(e.translation)", e.id) } label: { Label("İkisini kopyala", systemImage: "doc.on.clipboard") }
        }
    }

    private func copy(_ text: String, _ id: UUID) {
        UIPasteboard.general.string = text
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copiedID == id { copiedID = nil } }
    }
}
