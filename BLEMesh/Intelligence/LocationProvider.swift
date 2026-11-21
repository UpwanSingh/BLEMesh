import Foundation
import CoreLocation
import MeshCore

/// One-shot GPS fix for SOS reports (GPS works without any network).
@MainActor
enum LocationProvider {
    static func currentLocation(timeout: TimeInterval = 8) async -> GeoPoint? {
        let manager = CLLocationManager()
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

    var mapsURL: URL? {
        URL(string: "http://maps.apple.com/?ll=\(latitude),\(longitude)&q=SOS")
    }
}
