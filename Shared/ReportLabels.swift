import SwiftUI

struct MetricRow: View {
    let metric: HealthMetric
    let value: Double?

    var body: some View {
        LabeledContent(metric.title) {
            if let value {
                Text("\(metric.display(value)) \(metric.unit)")
                    .monospacedDigit()
            } else {
                Text("无数据").foregroundStyle(.secondary)
            }
        }
    }
}

struct JournalNotice: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("恩名手记", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}
