import MapKit
import SwiftUI

/// Displays a recorded area without looking up a street address or requesting location access.
struct MeetingLocationView: View {
    let location: MeetingLocation?

    var body: some View {
        if let location {
            let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
            if CLLocationCoordinate2DIsValid(coordinate) {
                mapPreview(at: coordinate, accuracy: location.accuracy.flatMap { (1...100_000).contains($0) ? $0 : nil })
            } else {
                unavailable("录音地点不可用")
            }
        } else {
            unavailable("未记录录音地点")
        }
    }

    private func mapPreview(at coordinate: CLLocationCoordinate2D, accuracy: Double?) -> some View {
        let span = max(900, (accuracy ?? 0) * 4.5)
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: span, longitudinalMeters: span)
        return VStack(alignment: .leading, spacing: 8) {
            Label(accuracy.map { "录音开始附近 · 约 \($0.formatted(.number.precision(.fractionLength(0)))) 米范围" }
                  ?? "录音开始附近 · 大致位置", systemImage: "location.circle")
                .font(.subheadline)
                .accessibilityIdentifier("meeting-location.preview")
            // A preview inside a list should not compete for vertical scrolling.
            Map(initialPosition: .region(region), interactionModes: []) {
                if let accuracy {
                    MapCircle(center: coordinate, radius: accuracy)
                        .foregroundStyle(.teal.opacity(0.2))
                        .stroke(.teal, lineWidth: 2)
                } else {
                    Marker("录音开始附近", coordinate: coordinate)
                        .tint(.teal)
                }
            }
            .frame(height: 156)
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
    }

    private func unavailable(_ text: String) -> some View {
        Label(text, systemImage: "location.slash")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

}
