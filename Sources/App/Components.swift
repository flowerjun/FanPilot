import SwiftUI

// Small building blocks shared by every tab. Each is a plain view with no state of its own.

/// Rounded card background, optionally highlighted (selected preset, active setup).
struct Card: ViewModifier {
    var selected = false

    func body(content: Content) -> some View {
        content
            .padding(8)
            // Fill the grid cell, top-aligned, so cards in one row share a height.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(selected ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}

extension View {
    func card(selected: Bool = false) -> some View { modifier(Card(selected: selected)) }
}

/// Horizontal bar made of colored segments, each a fraction (0…1) of the full width.
struct UsageBar: View {
    struct Segment { let fraction: Double; let color: Color }
    let segments: [Segment]
    var height: CGFloat = 6

    init(_ segments: [Segment], height: CGFloat = 6) { self.segments = segments; self.height = height }
    init(fraction: Double, color: Color, height: CGFloat = 6) { self.init([.init(fraction: fraction, color: color)], height: height) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { i in
                    segments[i].color.frame(width: geo.size.width * CGFloat(min(max(segments[i].fraction, 0), 1)))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.1))
            .clipShape(Capsule())
        }
        .frame(height: height)
    }

    /// Green → orange → red by load, the usual reading of a usage bar.
    static func loadColor(_ percent: Double) -> Color {
        percent >= 85 ? .red : percent >= 60 ? .orange : .green
    }
}

/// Title row, a large value, then free-form content underneath.
struct MetricCard<Content: View>: View {
    let title: String
    var detail: String?
    var detailColor: Color = .secondary
    let value: String
    var unit: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.caption.bold())
                Spacer(minLength: 4)
                if let detail { Text(detail).font(.caption2).foregroundStyle(detailColor).lineLimit(1) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(.title3, design: .rounded).monospacedDigit()).bold()
                if let unit { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
            content
        }
        .card()
    }
}

/// One short bar per core, grouped (e.g. efficiency / performance) with a label under each group.
struct CoreBars: View {
    struct Group { let label: String; let values: [Double] }
    let groups: [Group]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(groups.indices, id: \.self) { g in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(groups[g].values.indices, id: \.self) { i in
                            let v = groups[g].values[i]
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.1))
                                RoundedRectangle(cornerRadius: 1.5).fill(UsageBar.loadColor(v))
                                    .frame(height: max(1, 22 * CGFloat(min(v, 100)) / 100))
                            }
                            .frame(width: 6, height: 22)
                        }
                    }
                    Text(groups[g].label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Small colored dot + label, for chart and bar legends.
struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }
}

enum Format {
    /// Bytes as GB with one decimal under 100 GB, whole numbers above (e.g. "25.9 GB", "926 GB").
    static func gigabytes(_ bytes: Double) -> String {
        let gb = bytes / 1_073_741_824
        return gb < 100 ? String(format: "%.1f GB", gb) : String(format: "%.0f GB", gb)
    }

    static func percent(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "--" }

    static func rpm(_ v: Double?) -> String { v.map { "\(Int($0))" } ?? "--" }
}
