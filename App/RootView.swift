import SwiftUI

/// Uygulamanın ana çatısı. Sekmeler aynı anda bellekte tutulur; böylece yüzen kutunun katmanı
/// sekme değişse de pencerede kalır (iOS'un kutuyu çalıştırmaya devam etmesi için gerekli).
struct RootView: View {
    @EnvironmentObject private var s: AppSettings
    @EnvironmentObject private var engine: Engine
    @ObservedObject private var router = AppRouter.shared
    @State private var visited: Set<AppTab> = [.screen]
    @State private var showOnboarding = false

    var body: some View {
        ZStack {
            ForEach(AppTab.allCases, id: \.self) { tab in
                if visited.contains(tab) {
                    content(for: tab)
                        .opacity(router.tab == tab ? 1 : 0)
                        .allowsHitTesting(router.tab == tab)
                        .accessibilityHidden(router.tab != tab)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabBar(selection: $router.tab)
        }
        .onChange(of: router.tab) { _, tab in visited.insert(tab) }
        .onChange(of: s.onboardingDone) { _, done in if !done { showOnboarding = true } }
        .onAppear {
            visited.insert(router.tab)
            if !s.onboardingDone { showOnboarding = true }
            UpdateChecker.shared.check()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                s.onboardingDone = true
                showOnboarding = false
            }
            .interactiveDismissDisabled()
        }
        .preferredColorScheme(s.appTheme.scheme)
        .tint(s.accent.color)
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .screen: ScreenTab()
        case .camera: CameraTab()
        case .history: HistoryView()
        case .settings: SettingsTab()
        }
    }
}

struct TabBar: View {
    @Binding var selection: AppTab
    @EnvironmentObject private var engine: Engine

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(height: 24)
                            if isLive(tab) {
                                Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: 7, y: -1)
                            }
                        }
                        Text(tab.title).font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                    .foregroundStyle(selection == tab ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func isLive(_ tab: AppTab) -> Bool {
        guard engine.running else { return false }
        return (tab == .screen && engine.runMode == .screen) || (tab == .camera && engine.runMode == .camera)
    }
}

// MARK: - Ortak parçalar

/// Durum satırı: renkli nokta + mesaj.
struct StatusRow: View {
    let connected: Bool
    let running: Bool
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Color.green : (running ? Color.orange : Color.gray))
                .frame(width: 9, height: 9)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Büyük başlat/durdur düğmesi.
struct PrimaryButton: View {
    let running: Bool
    let startTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(running ? "Durdur" : startTitle, systemImage: running ? "stop.fill" : "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(running ? .red : nil)
        .controlSize(.large)
    }
}

/// Kaynak ve hedef dil seçimi (+ yer değiştirme).
struct LanguageBar: View {
    @EnvironmentObject private var s: AppSettings
    let sourceOptions: [Lang]
    let showTarget: Bool

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Videonun dili", selection: $s.sourceLang) {
                    ForEach(sourceOptions) { Text($0.name).tag($0.id) }
                }
            } label: {
                chip(title: "Videonun dili", value: Languages.source(s.sourceLang)?.name ?? s.sourceLang)
            }
            if showTarget {
                Button {
                    if let sw = Languages.swapped(source: s.sourceLang, target: s.targetLang) {
                        s.sourceLang = sw.source
                        s.targetLang = sw.target
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .disabled(Languages.swapped(source: s.sourceLang, target: s.targetLang) == nil)
                Menu {
                    Picker("Çeviri dili", selection: $s.targetLang) {
                        ForEach(Languages.targets) { Text($0.name).tag($0.id) }
                    }
                } label: {
                    chip(title: "Çeviri dili", value: Languages.target(s.targetLang)?.name ?? s.targetLang)
                }
            }
        }
    }

    private func chip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill)))
    }
}

/// Hızlı profil kartları.
struct PresetStrip: View {
    @EnvironmentObject private var s: AppSettings
    var onApplied: (AppSettings.Preset) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(AppSettings.Preset.allCases) { p in
                    Button {
                        s.apply(p)
                        onApplied(p)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: p.icon).font(.title3).foregroundStyle(.tint)
                            Text(p.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(p.detail).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(3).multilineTextAlignment(.leading)
                        }
                        .frame(width: 150, height: 104, alignment: .topLeading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - İlk açılış rehberi

struct OnboardingView: View {
    let done: () -> Void
    @State private var page = 0

    private let pages: [(icon: String, title: String, text: String)] = [
        ("captions.bubble.fill", "Her videoya anlık çeviri",
         "YouTube, TikTok, Instagram… Telefonda ne oynarsa, her uygulamanın üstünde duran kutuda anında Türkçesi çıkar."),
        ("pip.fill", "Ekran modu",
         "Başlat'a dokun, açılan pencerede “Yayını Başlat” de ve videoya geç. Altyazılı videolarda “Altyazıyı oku” en doğru sonucu verir; uygulama altyazının yerini kendisi bulur."),
        ("camera.viewfinder", "Kamera / TV modu",
         "Telefonu ya da iPad'i TV'ye tut: ekrandaki altyazıyı okur veya konuşmayı dinler. İstersen çeviriyi sesli de okur. Tamamen ücretsiz ve cihaz içinde."),
        ("button.programmable", "Tek dokunuşla başlat",
         "iPhone'un Eylem Düğmesi'ne ya da Siri'ye “Canlı Çeviri ile ekranı çevir” kısayolunu atayabilirsin. Ayarlar > Kısayollar bölümüne bak."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: pages[i].icon)
                            .font(.system(size: 64, weight: .semibold))
                            .foregroundStyle(.tint)
                        Text(pages[i].title).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(pages[i].text)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .padding(.horizontal, 32)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < pages.count - 1 { withAnimation { page += 1 } } else { done() }
            } label: {
                Text(page < pages.count - 1 ? "Devam" : "Başlayalım")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(24)
        }
    }
}
