import Testing
@testable import MeshCore

@Suite("Offline directions")
struct NavigationTests {
    let indiaGate = GeoPoint(latitude: 28.6129, longitude: 77.2295)
    let connaughtPlace = GeoPoint(latitude: 28.6315, longitude: 77.2167)

    @Test func distancesMatchKnownValues() {
        // India Gate → Connaught Place is about 2.4 km.
        let d = indiaGate.distance(to: connaughtPlace)
        #expect(abs(d - 2_430) < 60, "\(d)")
        #expect(indiaGate.distance(to: indiaGate) == 0)
        // One degree of latitude ≈ 111.2 km.
        #expect(abs(GeoPoint(latitude: 0, longitude: 0).distance(to: GeoPoint(latitude: 1, longitude: 0)) - 111_195) < 10)
    }

    @Test func bearingsAndCompassPoints() {
        let origin = GeoPoint(latitude: 28.6, longitude: 77.2)
        #expect(origin.compassPoint(to: GeoPoint(latitude: 28.61, longitude: 77.2)) == .n)
        #expect(origin.compassPoint(to: GeoPoint(latitude: 28.6, longitude: 77.21)) == .e)
        #expect(origin.compassPoint(to: GeoPoint(latitude: 28.59, longitude: 77.2)) == .s)
        #expect(origin.compassPoint(to: GeoPoint(latitude: 28.6, longitude: 77.19)) == .w)
        #expect(origin.compassPoint(to: GeoPoint(latitude: 28.61, longitude: 77.21)) == .ne)
        #expect(origin.compassPoint(to: GeoPoint(latitude: 28.59, longitude: 77.19)) == .sw)
        #expect(indiaGate.compassPoint(to: connaughtPlace) == .nw)
    }

    @Test func humanDirections() {
        let me = GeoPoint(latitude: 28.6125, longitude: 77.2065, accuracyMeters: 10)
        let sos = GeoPoint(latitude: 28.6139, longitude: 77.2090, accuracyMeters: 25)
        #expect(me.directions(to: sos) == "290 m NE")
        #expect(indiaGate.directions(to: connaughtPlace) == "2.4 km NW")
        #expect(me.directions(to: GeoPoint(latitude: 28.61255, longitude: 77.20652)) == "here")
    }

    @Test func landmarksStopAtJoiningWords() {
        #expect(HeuristicTriage.locationHints(in: "Elderly man fell near the bus stand and can't move his leg") == ["the bus stand"])
        #expect(HeuristicTriage.locationHints(in: "Fire near the market, lots of smoke") == ["the market"])
        #expect(HeuristicTriage.locationHints(in: "trapped behind the school, one is bleeding") == ["the school"])
        #expect(HeuristicTriage.locationHints(in: "stuck near gate 4 with my kids").first == "gate 4")
    }
}
