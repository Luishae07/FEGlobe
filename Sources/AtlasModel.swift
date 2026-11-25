import SwiftUI
import MapKit

/// A place to fly to.
struct Place: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
    /// how far the camera stands, in metres
    var distance: Double = 1200
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Where the camera of the globe is (both engines report it).
struct CameraState: Equatable {
    var latitude = 30.0
    var longitude = 10.0
    var distance = 20_000_000.0
    var heading = 0.0
}

/// "Fly there": the globe views watch `id`.
struct FlyRequest: Equatable {
    let id = UUID()
    var latitude: Double
    var longitude: Double
    var distance: Double
    var heading: Double = 0
    var tilted: Bool = true
}

@MainActor
final class AtlasModel: ObservableObject {
    @Published var camera = CameraState()
    @Published var request: FlyRequest?
    @Published var selected: Place?
    @Published var tilted = true

    func fly(to place: Place) {
        selected = place
        request = FlyRequest(latitude: place.latitude, longitude: place.longitude, distance: place.distance, tilted: tilted)
    }

    func toggleTilt() {
        tilted.toggle()
        request = FlyRequest(latitude: camera.latitude, longitude: camera.longitude, distance: camera.distance, heading: camera.heading, tilted: tilted)
    }

    func faceNorth() {
        request = FlyRequest(latitude: camera.latitude, longitude: camera.longitude, distance: camera.distance, heading: 0, tilted: tilted)
    }
}
