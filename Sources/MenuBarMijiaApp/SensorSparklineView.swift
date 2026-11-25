import SwiftUI
import MijiaCore

/// Pure geometry and bounds computation for the 24-hour sensor hover sparkline.
///
/// Mirrors `itsyhome-macos:SparklineView.swift` (`numericMinRange = 5` for temperature) so
/// minor 1-degree fluctuations do not turn into exaggerated sawtooth spikes, and reads solely
/// from the existing local `SensorHistory` store without triggering network requests.
enum SensorSparklineModel {
    struct Layout: Equatable, Sendable {
        let metric: SensorMetricKind
        let coords: [CGPoint]
        let yMin: Double
        let yMax: Double
        let observedMin: Double
        let observedMax: Double
        let latest: Double
        let observedCount: Int
        let slotCount: Int
    }

    static func numericMinRange(for metric: SensorMetricKind) -> Double {
        switch metric {
        case .temperature: return 5.0
        case .humidity: return 10.0
        }
    }

    static func preferredMetric(
        for points: [SensorHistoryPoint],
        requested: SensorMetricKind?
    ) -> SensorMetricKind? {
        if let requested, points.contains(where: { $0.value(for: requested) != nil }) {
            return requested
        }
        if points.contains(where: { $0.value(for: .temperature) != nil }) {
            return .temperature
        }
        if points.contains(where: { $0.value(for: .humidity) != nil }) {
            return .humidity
        }
        return nil
    }

    static func yBounds(
        observedValues: [Double],
        metric: SensorMetricKind
    ) -> (min: Double, max: Double)? {
        guard let rawMin = observedValues.min(),
              let rawMax = observedValues.max(),
              rawMin.isFinite,
              rawMax.isFinite else {
            return nil
        }
        let minRange = numericMinRange(for: metric)
        let rawSpan = rawMax - rawMin
        var lo: Double
        var hi: Double
        if rawSpan < minRange {
            let mid = (rawMin + rawMax) / 2
            lo = mid - minRange / 2
            hi = mid + minRange / 2
        } else {
            let pad = rawSpan * 0.12
            lo = rawMin - pad
            hi = rawMax + pad
        }
        if metric == .humidity {
            lo = max(0, lo)
            hi = min(100, hi)
            if hi - lo < minRange {
                if lo <= 0 {
                    hi = min(100, minRange)
                } else if hi >= 100 {
                    lo = max(0, 100 - minRange)
                }
            }
        }
        return (lo, max(hi, lo + 0.1))
    }

    static func compute(
        points: [SensorHistoryPoint],
        metric: SensorMetricKind,
        size: CGSize,
        padding: CGFloat = 2.5
    ) -> Layout? {
        let observed: [(index: Int, value: Double)] = points.enumerated().compactMap { idx, pt in
            guard let v = pt.value(for: metric), v.isFinite else { return nil }
            return (idx, v)
        }
        guard !observed.isEmpty,
              let bounds = yBounds(observedValues: observed.map(\.value), metric: metric),
              let latest = observed.last?.value,
              let observedMin = observed.map(\.value).min(),
              let observedMax = observed.map(\.value).max() else {
            return nil
        }
        let span = max(bounds.max - bounds.min, 0.1)
        let innerW = max(size.width - padding * 2, 1)
        let innerH = max(size.height - padding * 2, 1)
        let slotDenom = max(points.count - 1, 1)

        let coords: [CGPoint] = observed.map { item in
            let x: CGFloat = points.count <= 1
                ? padding + innerW / 2
                : padding + (CGFloat(item.index) / CGFloat(slotDenom)) * innerW
            let normalized = min(max((item.value - bounds.min) / span, 0), 1)
            let y = padding + innerH * CGFloat(1 - normalized)
            return CGPoint(x: x, y: y)
        }

        return Layout(
            metric: metric,
            coords: coords,
            yMin: bounds.min,
            yMax: bounds.max,
            observedMin: observedMin,
            observedMax: observedMax,
            latest: latest,
            observedCount: observed.count,
            slotCount: points.count
        )
    }

    static func rangeLabel(layout: Layout) -> String {
        switch layout.metric {
        case .temperature:
            let lo = L10n.temperatureValue(layout.observedMin, fractionDigits: 1)
            let hi = L10n.temperatureValue(layout.observedMax, fractionDigits: 1)
            if lo == hi {
                return "\(hi)\(L10n.temperatureSymbol)"
            }
            return "\(lo)–\(hi)\(L10n.temperatureSymbol)"
        case .humidity:
            let lo = Int(layout.observedMin.rounded())
            let hi = Int(layout.observedMax.rounded())
            if lo == hi {
                return "\(hi)%"
            }
            return "\(lo)–\(hi)%"
        }
    }

    static func smoothLinePath(coords: [CGPoint]) -> Path {
        Path { path in
            guard let first = coords.first else { return }
            path.move(to: first)
            guard coords.count > 1 else { return }
            for idx in 1..<coords.count {
                let prev = coords[idx - 1]
                let cur = coords[idx]
                let midX = (prev.x + cur.x) / 2
                path.addCurve(
                    to: cur,
                    control1: CGPoint(x: midX, y: prev.y),
                    control2: CGPoint(x: midX, y: cur.y)
                )
            }
        }
    }
}

/// Compact translucent 24-hour sparkline pill shown while hovering a sensor card reading.
struct SensorSparklineOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency

    let layout: SensorSparklineModel.Layout
    let tint: Color
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 2 : 3) {
            HStack(spacing: 4) {
                Text("24h")
                    .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                Spacer(minLength: 2)
                Text(SensorSparklineModel.rangeLabel(layout: layout))
                    .font(.system(size: DesignTokens.TypeSize.footnote, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                sparklinePlot(layout, size: geo.size)
            }
            .frame(height: isCompact ? 16 : 22)
        }
        .padding(.horizontal, isCompact ? 7 : 8)
        .padding(.vertical, isCompact ? 4 : 5)
        .frame(width: isCompact ? 104 : 132)
        .background {
            let shape = RoundedRectangle(cornerRadius: isCompact ? 10 : 11, style: .continuous)
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: isCompact ? 10 : 11, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    lineWidth: DesignTokens.hairline
                )
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.08), radius: 5, y: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func sparklinePlot(_ plot: SensorSparklineModel.Layout, size: CGSize) -> some View {
        let coords = normalizedCoords(from: plot, in: size)
        ZStack {
            if coords.count >= 2 {
                let line = SensorSparklineModel.smoothLinePath(coords: coords)
                areaPath(line: line, coords: coords, baselineY: size.height - 1)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.28), tint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                line.stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
                if let last = coords.last {
                    Circle()
                        .fill(tint)
                        .frame(width: 4.5, height: 4.5)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 0.8))
                        .position(last)
                }
            } else if let only = coords.first {
                Path { p in
                    p.move(to: CGPoint(x: 2, y: only.y))
                    p.addLine(to: CGPoint(x: max(size.width - 2, 2), y: only.y))
                }
                .stroke(tint.opacity(0.45), style: StrokeStyle(lineWidth: 1.1, dash: [3, 2.5]))
                Circle()
                    .fill(tint)
                    .frame(width: 4.5, height: 4.5)
                    .position(only)
            }
        }
    }

    private func normalizedCoords(from source: SensorSparklineModel.Layout, in size: CGSize) -> [CGPoint] {
        guard !source.coords.isEmpty else { return [] }
        // `layout` is already computed for the canonical canvas size (116 x 22 / 90 x 16);
        // scale proportionally if the container differs.
        let refSize = SensorSparklineOverlay.referencePlotSize(isCompact: isCompact)
        let sx = refSize.width > 0 ? size.width / refSize.width : 1
        let sy = refSize.height > 0 ? size.height / refSize.height : 1
        return source.coords.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
    }

    private func areaPath(line: Path, coords: [CGPoint], baselineY: CGFloat) -> Path {
        var path = line
        if let last = coords.last, let first = coords.first {
            path.addLine(to: CGPoint(x: last.x, y: baselineY))
            path.addLine(to: CGPoint(x: first.x, y: baselineY))
            path.closeSubpath()
        }
        return path
    }

    static func referencePlotSize(isCompact: Bool) -> CGSize {
        isCompact ? CGSize(width: 90, height: 16) : CGSize(width: 116, height: 22)
    }
}

extension View {
    /// Attaches the non-interactive 24h hover sparkline overlay when a sensor reading is hovered
    /// on a collapsed, online, fresh sensor card. Reads solely from existing local `SensorHistory`.
    @ViewBuilder
    func sensorReadingHoverSparkline(
        store: HomeStore?,
        device: SmartDevice,
        hoveredMetric: SensorMetricKind?,
        isActive: Bool,
        isCompact: Bool,
        tempColor: Color,
        humidityColor: Color,
        reduceMotion: Bool
    ) -> some View {
        let resolved: (layout: SensorSparklineModel.Layout, metric: SensorMetricKind)? = {
            guard isActive, let hoveredMetric, let store else { return nil }
            let points = store.sensorHistory.points(forDevice: device.id, window: .last24Hours)
            guard let metric = SensorSparklineModel.preferredMetric(for: points, requested: hoveredMetric),
                  let layout = SensorSparklineModel.compute(
                    points: points,
                    metric: metric,
                    size: SensorSparklineOverlay.referencePlotSize(isCompact: isCompact)
                  ) else {
                return nil
            }
            return (layout, metric)
        }()

        let alignment: Alignment = isCompact
            ? .trailing
            : (resolved?.metric == .humidity ? .bottomLeading : .bottomTrailing)

        overlay(alignment: alignment) {
            if let resolved {
                SensorSparklineOverlay(
                    layout: resolved.layout,
                    tint: resolved.metric == .temperature ? tempColor : humidityColor,
                    isCompact: isCompact
                )
                .padding(isCompact ? 5 : 8)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(AppleMotion.resolve(.hoverFade, reduceMotion: reduceMotion), value: resolved?.metric)
    }
}
