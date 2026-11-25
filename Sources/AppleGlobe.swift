import SwiftUI
import MapKit

/// Apple's globe with its own 3D cities (no key needed).
struct AppleGlobe: View {
    @ObservedObject var model: AtlasModel
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            UserAnnotation()
            if let place = model.selected {
                Marker(place.name, coordinate: place.coordinate)
            }
        }
        .mapStyle(.hybrid(elevation: .realistic))
        .mapControls { MapScaleView() }
        .onMapCameraChange { context in
            let c = context.camera
            model.camera = CameraState(latitude: c.centerCoordinate.latitude, longitude: c.centerCoordinate.longitude,
                                       distance: c.distance, heading: c.heading)
        }
        .onChange(of: model.request) { _, request in
            guard let request else { return }
            withAnimation(.easeInOut(duration: 2)) { position = camera(for: request) }
        }
        .onAppear {
            let c = model.camera
            position = camera(for: FlyRequest(latitude: c.latitude, longitude: c.longitude, distance: c.distance,
                                              heading: c.heading, tilted: model.tilted && c.distance < 100_000))
        }
    }

    private func camera(for r: FlyRequest) -> MapCameraPosition {
        .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude),
                          distance: r.distance, heading: r.heading, pitch: r.tilted ? 60 : 0))
    }
}
