import Foundation
import CoreLocation
import MeshCore

/// One-shot GPS fix for SOS reports (GPS works without any network).
@MainActor
enum LocationProvider {
    private static let manager = CLLocationManager()

    static var isAuthorized: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
    }

    static func currentLocation(timeout: TimeInterval = 8) async -> GeoPoint? {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        return await withTaskGroup(of: GeoPoint?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 200 {
                            return GeoPoint(latitude: location.coordinate.latitude,
                                            longitude: location.coordinate.longitude,
                                            accuracyMeters: location.horizontalAccuracy)
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

extension GeoPoint {
    var formatted: String {
        String(format: "%.5f, %.5f", latitude, longitude) + (accuracyMeters.map { String(format: " (±%.0f m)", $0) } ?? "")
    }

    /// Localized "290 m NE" / "2.4 km NW" / "here" — computed on the phone, no network needed.
    func localizedDirections(to other: GeoPoint) -> String {
        let metres = distance(to: other)
        if metres <= max(15, (accuracyMeters ?? 0) + (other.accuracyMeters ?? 0)) { return L("here") }
        let distance = metres < 1000
            ? Measurement(value: (metres / 10).rounded() * 10, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
            : Measurement(value: metres / 1000, unit: UnitLength.kilometers)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        return "\(distance) \(L(compassPoint(to: other).rawValue))"
    }

    var mapsURL: URL? {
        URL(string: "http://maps.apple.com/?ll=\(latitude),\(longitude)&q=SOS")
    }
}
