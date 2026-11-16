import AppKit
import SwiftUI

/// `ApproveGateBar --snapshot DIR [--dark]`: renders each Settings page off-screen to DIR/<page>.png,
/// including AppKit-backed controls, so the window can be checked without screen capture rights.
@MainActor
enum Snapshot {
    static func run(_ dir: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let store = Store.shared
        let sema = DispatchSemaphore(value: 0)
        Task {
            await store.load()
            await Monitor.shared.refresh()
            sema.signal()
        }
        while sema.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let pages: [(String, AnyView)] = [
            ("1-overview", AnyView(OverviewPage(go: { _ in }))),
            ("2-commands", AnyView(CommandsPage())),
            ("2b-commands-off", AnyView(CommandsPage())),
            ("3-approval", AnyView(ApprovalPage())),
            ("4-phone", AnyView(PhonePage())),
            ("5-secrets", AnyView(SecretsPage())),
            ("6-claude", AnyView(ClaudePage())),
            ("7-activity", AnyView(ActivityPage())),
            ("8-add-command", AnyView(AddCommandSheet { _ in })),
            ("9-pair", AnyView(PairPreview())),
            ("9b-pair-code", AnyView(PairCodePreview())),
        ]
        for (name, view) in pages {
            // The same page with the first command's gating turned off, in the draft only (never saved).
            if name == "2b-commands-off", let first = store.draft?.clis.keys.sorted().first { store.update(first) { $0.disabled = true } }
            if name == "3-approval" { store.revert() }
            let size = name == "8-add-command" ? NSSize(width: 600, height: 470) : name.hasPrefix("9") ? NSSize(width: 420, height: 470) : NSSize(width: 720, height: 640)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            // Let tasks and layout settle.
            for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            print("\(dir)/\(name).png")
        }
    }
}

/// The pairing sheet in its "scan" state, with a sample link (no real key).
struct PairPreview: View {
    var body: some View {
        VStack(spacing: 18) {
            Text("Pair a phone").font(.title2.bold())
            QRCode(text: "approvegate://pair?s=https://relay.example&q=ag-sample&r=ag-sample&k=sample&m=Mac")
                .frame(width: 240, height: 240).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12))
            VStack(spacing: 4) {
                Text("Scan with the Approve Gate app").font(.headline)
                Text("Open the app, tap Scan pairing code, then confirm with your fingerprint. The phone then shows a code; this Mac shows the same code before you approve.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack { Spacer(); Button("Cancel") {} }
        }
        .padding(24)
    }
}

/// The pairing sheet once a phone has answered: the code to compare (sample values).
struct PairCodePreview: View {
    var body: some View {
        VStack(spacing: 18) {
            Text("Pair a phone").font(.title2.bold())
            VStack(spacing: 12) {
                Image(systemName: "touchid").font(.system(size: 54)).foregroundStyle(.pink)
                Text("Check the code").font(.headline)
                Text("482 913").font(.system(size: 34, weight: .semibold, design: .monospaced))
                Text("Pixel 8 answered. Approve with Touch ID only if your phone shows this same code. If it shows a different code, deny: another program tried to pair.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }.frame(height: 300)
            HStack { Spacer(); Button("Cancel") {} }
        }
        .padding(24)
    }
}
