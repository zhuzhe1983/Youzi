import SwiftUI

/// Compact circular ring indicating the current session's context window usage.
/// Clamped between 0% and 100%, color-coded by token pressure.
struct YouziContextUsageRing: View {
    let messages: [ChatMessage]
    let alias: String

    private var estimatedTokens: Int {
        messages.reduce(0) { sum, msg in
            let contentChars = msg.modelContent.count
            let toolArgsChars = (msg.toolCalls ?? []).reduce(0) { $0 + $1.function.arguments.count }
            return sum + max(1, (contentChars + toolArgsChars) / 4)
        }
    }

    private var contextWindow: Int {
        ModelInfoCatalog.contextWindowFallback(forAlias: alias) ?? 4096
    }

    private var ratio: Double {
        guard contextWindow > 0 else { return 0 }
        return min(1.0, max(0.0, Double(estimatedTokens) / Double(contextWindow)))
    }

    private var percent: Int {
        Int(round(ratio * 100))
    }

    private var ringColor: Color {
        if ratio >= 0.90 {
            return RapidTheme.statusError
        } else if ratio >= 0.70 {
            return RapidTheme.statusWarning
        } else {
            return RapidTheme.brandPrimary
        }
    }

    var body: some View {
        HStack(spacing: RapidTheme.Space.xxs) {
            ZStack {
                Circle()
                    .stroke(RapidTheme.hairlineStrong, lineWidth: 2)
                    .frame(width: 14, height: 14)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, ratio)))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 14, height: 14)
            }
            Text("\(percent)%")
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
        }
        .help("上下文窗口使用率: \(percent)% (\(estimatedTokens) / \(contextWindow) tokens)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("上下文使用率 \(percent)%")
        .accessibilityIdentifier("YouziSimple.NewTask.ContextUsage")
    }
}
