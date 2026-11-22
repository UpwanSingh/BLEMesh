import Foundation

/// Offline navigation between two GPS fixes: no maps or network needed.
extension GeoPoint {
    private static let earthRadius = 6_371_000.0

    /// Great-circle distance in metres (haversine).
    public func distance(to other: GeoPoint) -> Double {
        let φ1 = latitude * .pi / 180, φ2 = other.latitude * .pi / 180
        let Δφ = (other.latitude - latitude) * .pi / 180
        let Δλ = (other.longitude - longitude) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * Self.earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Initial compass bearing to `other` in degrees (0 = north, 90 = east).
    public func bearing(to other: GeoPoint) -> Double {
        let φ1 = latitude * .pi / 180, φ2 = other.latitude * .pi / 180
        let Δλ = (other.longitude - longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    public enum CompassPoint: String, CaseIterable, Sendable {
        case n = "N", ne = "NE", e = "E", se = "SE", s = "S", sw = "SW", w = "W", nw = "NW"
    }

    /// Eight-point compass direction to `other`.
    public func compassPoint(to other: GeoPoint) -> CompassPoint {
        let index = Int((bearing(to: other) + 22.5) / 45) % 8
        return CompassPoint.allCases[index]
    }

    /// "350 m NE", "1.2 km S"; "here" within the combined GPS uncertainty (min 15 m).
    public func directions(to other: GeoPoint) -> String {
        let metres = distance(to: other)
        let uncertainty = max(15, (accuracyMeters ?? 0) + (other.accuracyMeters ?? 0))
        if metres <= uncertainty { return "here" }
        let point = compassPoint(to: other).rawValue
        if metres < 1000 { return "\(Int((metres / 10).rounded()) * 10) m \(point)" }
        return String(format: "%.1f km %@", metres / 1000, point)
    }
}
