import SwiftUI

/// Görüntü üzerinde 4 köşesinden boyutlandırılan, içinden sürüklenen okuma alanı.
struct AreaEditor: View {
    @Binding var rect: CGRect
    var label: String = "Altyazı alanı"
    @State private var start: CGRect?

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { g in
            let W = max(1, g.size.width), H = max(1, g.size.height)
            let r = CGRect(x: rect.minX * W, y: rect.minY * H, width: rect.width * W, height: rect.height * H)
            ZStack {
                // Alan dışını karart.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: g.size))
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // Alanın kendisi: içinden sürükleyerek taşı.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .background(Color.white.opacity(0.001))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                let s0 = start ?? rect
                                if start == nil { start = rect }
                                let x = min(max(0, s0.minX + v.translation.width / W), 1 - s0.width)
                                let y = min(max(0, s0.minY + v.translation.height / H), 1 - s0.height)
                                rect = CGRect(x: x, y: y, width: s0.width, height: s0.height)
                            }
                            .onEnded { _ in start = nil }
                    )

                Text(label)
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow))
                    .foregroundStyle(.black)
                    .position(x: min(max(r.midX, 60), W - 60), y: max(14, r.minY - 16))
                    .allowsHitTesting(false)

                ForEach(Corner.allCases, id: \.self) { c in
                    handle(c, r: r, W: W, H: H)
                }
            }
            .frame(width: W, height: H)
        }
    }

    private func point(_ c: Corner, _ r: CGRect) -> CGPoint {
        switch c {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func handle(_ c: Corner, r: CGRect, W: CGFloat, H: CGFloat) -> some View {
        Circle()
            .fill(Color.yellow)
            .frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1.5))
            .shadow(radius: 2)
            .frame(width: 48, height: 48)          // geniş dokunma alanı
            .contentShape(Rectangle())
            .position(point(c, r))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let s0 = start ?? rect
                        if start == nil { start = rect }
                        let dx = v.translation.width / W, dy = v.translation.height / H
                        var minX = s0.minX, minY = s0.minY, maxX = s0.maxX, maxY = s0.maxY
                        switch c {
                        case .topLeft: minX += dx; minY += dy
                        case .topRight: maxX += dx; minY += dy
                        case .bottomLeft: minX += dx; maxY += dy
                        case .bottomRight: maxX += dx; maxY += dy
                        }
                        minX = max(0, min(minX, maxX - 0.08))
                        maxX = min(1, max(maxX, minX + 0.08))
                        minY = max(0, min(minY, maxY - 0.04))
                        maxY = min(1, max(maxY, minY + 0.04))
                        rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

/// Ekran modunda altyazı alanını seçme ekranı. Dikey ve yatay video için ayrı alan kaydedilir.
struct AreaPickerView: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var s: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var landscape = false
    @State private var image: UIImage?
    @State private var readText = ""
    @State private var reading = false
    @State private var readWork: DispatchWorkItem?

    private var area: Binding<CGRect> { landscape ? $s.landscapeArea : $s.portraitArea }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Yön", selection: $landscape) {
                    Label("Dikey video", systemImage: "iphone").tag(false)
                    Label("Yatay / tam ekran", systemImage: "iphone.landscape").tag(true)
                }
                .pickerStyle(.segmented)

                canvas

                resultCard
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .navigationTitle("Altyazı alanı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Varsayılan") {
                        area.wrappedValue = landscape ? AppSettings.defaultLandscapeArea : AppSettings.defaultPortraitArea
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Bitti") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            // Elde hangi yönün görüntüsü varsa onunla başla.
            if !engine.hasPortraitShot && engine.hasLandscapeShot { landscape = true }
            load()
        }
        .onChange(of: landscape) { _, _ in load() }
        .onChange(of: area.wrappedValue) { _, _ in scheduleRead() }
    }

    private var canvas: some View {
        let aspect: CGFloat = image.map { $0.size.width / max(1, $0.size.height) } ?? (landscape ? 19.5 / 9 : 9 / 19.5)
        return ZStack {
            if let img = image {
                Image(uiImage: img).resizable()
            } else {
                placeholder
            }
            AreaEditor(rect: area)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.secondary.opacity(0.3)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Gerçek ekran görüntüsü yokken basit bir YouTube şeması.
    private var placeholder: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color(.secondarySystemBackground)
                if landscape {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.35))
                        .overlay(Text("Video").font(.caption).foregroundStyle(.secondary))
                    altyaziSketch(width: g.size.width * 0.5)
                        .position(x: g.size.width / 2, y: g.size.height * 0.85)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.35))
                        .frame(height: g.size.height * 0.28)
                        .overlay(Text("Video").font(.caption).foregroundStyle(.secondary))
                        .offset(y: g.size.height * 0.06)
                    altyaziSketch(width: g.size.width * 0.6)
                        .position(x: g.size.width / 2, y: g.size.height * 0.29)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                                .frame(width: g.size.width * (i % 2 == 0 ? 0.8 : 0.55), height: 8)
                        }
                    }
                    .offset(x: 12, y: g.size.height * 0.4)
                }
            }
        }
    }

    private func altyaziSketch(width: CGFloat) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.85)).frame(width: width, height: 5)
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.85)).frame(width: width * 0.8, height: 5)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.7)))
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if image != nil {
                HStack(spacing: 6) {
                    Text("Bu alanda okunan").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if reading { ProgressView().controlSize(.mini) }
                }
                Text(readText.isEmpty ? "(Bu alanda yazı bulunamadı)" : readText)
                    .font(.footnote)
                    .lineLimit(4)
                Text("Sarı çerçeveyi yalnızca altyazının çıktığı yere daralt; başlık, süre ve düğmeler dışarıda kalsın.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Gerçek ekran görüntüsü yok").font(.caption.weight(.semibold))
                Text("En doğru ayar için: Başlat → YouTube'da altyazılı bir videoyu \(landscape ? "yatay (tam ekran)" : "dikey") aç → 2–3 saniye bekle → bu uygulamaya dön ve burayı tekrar aç. Şimdilik şemaya göre de ayarlayabilirsin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func load() {
        image = engine.capturedShot(landscape: landscape)
        readText = ""
        scheduleRead(delay: 0.05)
    }

    private func scheduleRead(delay: Double = 0.35) {
        guard image != nil else { return }
        readWork?.cancel()
        let isLandscape = landscape
        let r = area.wrappedValue
        let w = DispatchWorkItem {
            reading = true
            engine.previewRead(landscape: isLandscape, area: r) { text in
                reading = false
                readText = text
            }
        }
        readWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

/// Seçili alanı gösteren küçük telefon simgesi.
struct AreaThumb: View {
    let rect: CGRect
    let landscape: Bool

    var body: some View {
        let size = landscape ? CGSize(width: 50, height: 25) : CGSize(width: 25, height: 50)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(Color(.tertiarySystemFill))
            Rectangle()
                .fill(Color.yellow.opacity(0.9))
                .frame(width: max(2, rect.width * size.width), height: max(2, rect.height * size.height))
                .offset(x: rect.minX * size.width, y: rect.minY * size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
    }
}
