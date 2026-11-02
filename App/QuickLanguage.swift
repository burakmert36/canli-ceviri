import SwiftUI

/// Son kullanılan dil çiftleri: tek dokunuşla geçiş (ör. İngilizce→Türkçe ⇄ Almanca→Türkçe).
struct QuickPairStrip: View {
    @EnvironmentObject private var s: AppSettings
    @EnvironmentObject private var engine: Engine
    var input: InputSource

    var body: some View {
        let pairs = s.quickPairs(input: input)
        if pairs.count >= 2 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(pairs) { p in
                        let selected = p == s.currentPair
                        Button {
                            guard !selected else { return }
                            UISelectionFeedbackGenerator().selectionChanged()
                            s.apply(p)
                            if engine.running { engine.flash("🌐 " + p.title) }
                        } label: {
                            Text(p.title)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(selected ? AnyShapeStyle(TintShapeStyle().opacity(0.18))
                                                            : AnyShapeStyle(Color(.tertiarySystemFill)))
                                )
                                .overlay(Capsule().strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear),
                                                                lineWidth: 1.2))
                                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dil çifti \(p.title)")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Yapay zekâ motorları için ek ayarlar: hibrit hız ve içerik türü.
struct AIOptionsView: View {
    @EnvironmentObject private var s: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $s.hybridLive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hibrit hız").font(.subheadline.weight(.semibold))
                    Text("Konuşurken ücretsiz hızlı çeviri, cümle bitince \(s.translator.shortName) ile son hâli. Daha hızlı, daha ucuz.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("İçerik türü").font(.subheadline)
                Spacer()
                Menu {
                    Picker("İçerik türü", selection: $s.contentKind) {
                        ForEach(ContentKind.allCases) { k in
                            Label(k.title, systemImage: k.icon).tag(k)
                        }
                    }
                } label: {
                    Label(s.contentKind.title, systemImage: s.contentKind.icon)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}
