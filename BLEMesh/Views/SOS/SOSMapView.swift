import SwiftUI
import MapKit
import MeshCore

/// SOS calls with a GPS fix, coloured by priority, plus this phone. Map tiles need internet;
/// the pins, distances and directions don't.
struct SOSMapView: View {
    let reports: [(StoredMessage, SOSReport)]
    let me: GeoPoint?

    private var located: [(StoredMessage, SOSReport, GeoPoint)] {
        reports.compactMap { message, report in report.location.map { (message, report, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Map(initialPosition: .automatic) {
                if let me {
                    Annotation("You", coordinate: me.coordinate) {
                        Circle().fill(Theme.Colors.accent).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .accessibilityIdentifier("sosmap.me")
                    }
                }
                ForEach(located, id: \.0.id) { message, report, point in
                    Annotation(message.isOutgoing ? String(localized: "Your SOS") : message.senderName, coordinate: point.coordinate) {
                        pin(for: report)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(accessibilityText(message: message, report: report, point: point)))
                            .accessibilityIdentifier("sosmap.pin")
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            Text(located.isEmpty ? "No SOS calls with a location yet."
                                 : "Map tiles need internet. Pins, distances and directions work offline.")
                .font(.caption2)
                .foregroundStyle(Theme.Colors.secondaryText)
                .padding(8)
        }
    }

    private func pin(for report: SOSReport) -> some View {
        let priority = report.triage?.priority ?? .high
        return Image(systemName: "sos.circle.fill")
            .font(.title)
            .foregroundStyle(.white, priority >= .critical ? Theme.Colors.danger : Theme.Colors.warning)
            .background(Circle().fill(.white).padding(4))
    }

    private func accessibilityText(message: StoredMessage, report: SOSReport, point: GeoPoint) -> String {
        var parts = [message.isOutgoing ? String(localized: "Your SOS") : message.senderName]
        if let triage = report.triage { parts.append(L(triage.priority.label) + " " + L(triage.category.label)) }
        if let me { parts.append(me.localizedDirections(to: point)) }
        return parts.joined(separator: ", ")
    }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
