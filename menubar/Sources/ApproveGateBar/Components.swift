import SwiftUI

/// Settings page shell: title, one-line description, readable column.
struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }
}

/// A rounded group of related settings.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let title { Text(title).font(.headline) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Tinted icon tile, title and caption, then a trailing control.
struct Row<Accessory: View>: View {
    let icon: String
    var tint: Color = .accentColor
    let title: String
    var caption: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension Row where Accessory == EmptyView {
    init(icon: String, tint: Color = .accentColor, title: String, caption: String? = nil) {
        self.init(icon: icon, tint: tint, title: title, caption: caption) { EmptyView() }
    }
}

/// Small coloured dot and label: ready, needs attention, off.
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7).shadow(color: color.opacity(0.6), radius: 2)
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// Editable list of short strings (patterns, flags, words) shown as removable chips, with an add field.
struct TokenList: View {
    @Binding var items: [String]
    let placeholder: String
    var monospaced = true
    /// Long lists show this many chips until "Show all".
    var collapseAfter: Int? = nil
    @State private var newItem = ""
    @State private var expanded = false

    private var shown: [String] {
        guard let n = collapseAfter, !expanded, items.count > n + 2 else { return items }
        return Array(items.prefix(n))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(shown, id: \.self) { item in
                        HStack(spacing: 4) {
                            Text(item).font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                            Button { items.removeAll { $0 == item } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove \(item)")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    if shown.count < items.count {
                        Button("Show all \(items.count)") { expanded = true }.buttonStyle(.link).font(.system(size: 12))
                    } else if expanded {
                        Button("Show fewer") { expanded = false }.buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
            HStack {
                TextField(placeholder, text: $newItem)
                    .textFieldStyle(.roundedBorder)
                    .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                    .onSubmit(add)
                Button("Add", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let v = newItem.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !items.contains(v) else { return }
        items.append(v)
        newItem = ""
    }
}

/// Wraps children onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// QR code drawn with sharp pixels.
struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
        } else {
            Image(systemName: "qrcode").font(.system(size: 80)).foregroundStyle(.secondary)
        }
    }

    static func image(_ text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
