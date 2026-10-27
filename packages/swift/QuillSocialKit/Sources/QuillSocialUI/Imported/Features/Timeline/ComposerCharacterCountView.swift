#if os(iOS)
import SwiftUI

struct ComposerCharacterCountView: View {
    let count: Int
    let limit: Int

    private var progress: Double {
        min(Double(count) / Double(limit), 1)
    }

    private var tint: AnyShapeStyle {
        if count > limit {
            AnyShapeStyle(.red)
        } else if count > limit - 20 {
            AnyShapeStyle(.orange)
        } else {
            AnyShapeStyle(.tint)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(limit - count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(count > limit ? .red : .secondary)
        }
        .frame(width: 34, height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Characters Remaining")
        .accessibilityValue("\(limit - count)")
    }
}

#endif
