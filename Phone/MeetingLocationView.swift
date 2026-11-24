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
                unavailable("会议地点不可用")
            }
        } else {
            unavailable("未记录会议地点")
        }
    }

    private func mapPreview(at coordinate: CLLocationCoordinate2D, accuracy: Double?) -> some View {
        let span = max(900, (accuracy ?? 0) * 4.5)
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: span, longitudinalMeters: span)
        return VStack(alignment: .leading, spacing: 8) {
            if let accuracy {
                Label("录音开始附近 · 约 \(accuracy.formatted(.number.precision(.fractionLength(0)))) 米范围",
                      systemImage: "location.circle")
                    .font(.subheadline)
            } else {
                Label("录音开始附近 · 大致位置", systemImage: "location.circle")
                    .font(.subheadline)
            }
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
            if let url = mapsURL(for: coordinate) {
                Link(destination: url) {
                    Label("在 Apple 地图中打开", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("查看录音开始附近的地图")
                .accessibilityIdentifier("meeting-location.open-maps")
            }
        }
        .padding(.vertical, 4)
    }

    private func unavailable(_ text: String) -> some View {
        Label(text, systemImage: "location.slash")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func mapsURL(for coordinate: CLLocationCoordinate2D) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "q", value: "录音开始附近")
        ]
        return components.url
    }
}
