import LLMCore
import SwiftUI

/// The live readout above the composer: decode speed with a small trace, time to first token,
/// tokens so far, and a thermal chip when the device runs hot.
///
/// It reads ``ChatViewModel/live`` itself, so the per-token updates re-render only this view.
struct InstrumentStrip: View {
    let chat: ChatViewModel
    let safety: SafetyMonitor

    @State private var trace = RateTrace()

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let live = chat.live
        let level = safety.thermalLevel
        let hot = safety.isThermalWarning
        Group {
            if let live {
                LiveReadout(live: live, trace: trace, thermal: hot ? level : nil)
            } else if dynamicTypeSize >= .xxLarge {
                VStack(alignment: .leading, spacing: 6) {
                    ThermalChip(level: level, compact: false)
                    ThermalMessage(level: level)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    ThermalMessage(level: level)
                    Spacer(minLength: 0)
                    ThermalChip(level: level, compact: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onChange(of: live?.fragments) { _, fragments in
            guard let live, let fragments else { return }
            trace.record(fragments: fragments, startedAt: live.startedAt)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Instantaneous decode rate, sampled from the fragment count over ~¼ s windows.
struct RateTrace {
    private(set) var samples: [Double] = []
    private var generationStart: Date?
    private var lastTime: Date?
    private var lastFragments = 0
    static let capacity = 12

    mutating func record(fragments: Int, startedAt: Date, now: Date = Date()) {
        if generationStart != startedAt {
            generationStart = startedAt
            samples = []
            lastTime = now
            lastFragments = fragments
            return
        }
        guard let lastTime else {
            self.lastTime = now
            lastFragments = fragments
            return
        }
        let elapsed = now.timeIntervalSince(lastTime)
        guard elapsed >= 0.25 else { return }
        samples.append(Double(fragments - lastFragments) / elapsed)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        self.lastTime = now
        lastFragments = fragments
    }
}

private struct LiveReadout: View {
    let live: LiveGenerationMetrics
    let trace: RateTrace
    /// Set when the device is hot while generating: a chip joins the row.
    let thermal: ThermalLevel?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showTrace: true, showTokens: true, compactChip: false)
            row(showTrace: false, showTokens: true, compactChip: false)
            row(showTrace: false, showTokens: false, compactChip: false)
            row(showTrace: false, showTokens: false, compactChip: true)
        }
    }

    private func row(showTrace: Bool, showTokens: Bool, compactChip: Bool) -> some View {
        HStack(spacing: 12) {
            readouts(showTrace: showTrace, showTokens: showTokens)
                .fixedSize()
            if let thermal {
                Spacer(minLength: 0)
                ThermalChip(level: thermal, compact: compactChip)
            }
        }
    }

    private func readouts(showTrace: Bool, showTokens: Bool) -> some View {
        HStack(spacing: 12) {
            PulsingDot(color: Theme.accent, size: 7)
            Readout(
                value: live.tokensPerSecond.map(Format.rate) ?? "–",
                unit: Text("tok/s"),
                emphasized: true)
            if showTrace {
                Sparkline(samples: trace.samples)
                    .frame(width: 50, height: 22)
            }
            Divider().frame(height: 26).overlay(Theme.hairline)
            FirstTokenGauge(live: live)
            if showTokens {
                Divider().frame(height: 26).overlay(Theme.hairline)
                Readout(value: "\(live.fragments)", unit: Text("tokens"), emphasized: false)
            }
        }
    }
}

/// Time to first token: counts up while the prompt is processed, then holds.
private struct FirstTokenGauge: View {
    let live: LiveGenerationMetrics

    var body: some View {
        if let ttft = live.timeToFirstToken {
            Readout(value: "\(Format.seconds(ttft)) s", unit: Text("first token"), emphasized: false)
        } else {
            TimelineView(.periodic(from: live.startedAt, by: 0.1)) { context in
                Readout(
                    value: "\(Format.seconds(max(0, context.date.timeIntervalSince(live.startedAt)))) s",
                    unit: Text("reading prompt"), emphasized: false)
            }
        }
    }
}

/// A number over a small label.
private struct Readout: View {
    let value: String
    let unit: Text
    let emphasized: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: value)
                .font(.mono(.subheadline, weight: .semibold))
                // Accent digits only on dark: orange text on white is below 4.5 : 1.
                .foregroundStyle(emphasized && colorScheme == .dark ? Theme.accent : Theme.textPrimary)
                .contentTransition(.numericText())
            unit
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .fixedSize()
    }
}

/// Bars of recent instantaneous decode rates.
private struct Sparkline: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            let count = RateTrace.capacity
            let gap: CGFloat = 2
            let barWidth = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            // Headroom above the peak so a steady rate does not fill every bar.
            let peak = max((samples.max() ?? 1) * 1.25, 1)
            let offset = count - samples.count
            for slot in 0..<count {
                let x = CGFloat(slot) * (barWidth + gap)
                let base = CGRect(x: x, y: size.height - 1.5, width: barWidth, height: 1.5)
                context.fill(Path(roundedRect: base, cornerRadius: 0.75), with: .color(Theme.hairline))
                let index = slot - offset
                guard index >= 0 else { continue }
                let fraction = max(0.08, min(1, samples[index] / peak))
                let height = max(1.5, size.height * fraction)
                let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
                // History in neutral grey, the newest sample in the accent (no faded orange,
                // which reads as brown on the dark background).
                let isNewest = index == samples.count - 1
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 1)),
                    with: .color(isNewest ? Theme.accent : Theme.textTertiary.opacity(0.75)))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ThermalChip: View {
    let level: ThermalLevel
    let compact: Bool

    var body: some View {
        let blocked = level >= .critical
        HStack(spacing: 5) {
            Image(systemName: blocked ? "thermometer.high" : "thermometer.medium")
                .symbolRenderingMode(.monochrome)
            if !compact {
                Text(blocked ? "Paused: device too hot" : "Hot")
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .font(.caption.weight(.semibold))
        .foregroundStyle(blocked ? Theme.critical : Theme.caution)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surfaceRaised, in: Capsule())
        .accessibilityLabel(
            blocked
                ? Text("Generation paused: device too hot") : Text("Device is hot; replies may slow down"))
    }
}

/// Shown in the strip when nothing is generating but the device is hot.
private struct ThermalMessage: View {
    let level: ThermalLevel

    var body: some View {
        Text(
            level >= .critical
                ? "Replies resume when it cools down."
                : "Running hot. Replies may be slower.")
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
