// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import MapKit

/// Apple's globe with its own 3D cities (no key needed). The 3D models of the Atlas are not shown on it.
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
        .mapControls {
            MapCompass()
            MapScaleView()
        }
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
            // coming from the other map: the same place
            let c = model.camera
            position = camera(for: FlyRequest(latitude: c.latitude, longitude: c.longitude, distance: c.distance,
                                              heading: c.heading, tilted: model.tilted && c.distance < 100_000))
        }
    }

    private func camera(for r: FlyRequest) -> MapCameraPosition {
        .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude),
                          distance: r.distance, heading: r.heading, pitch: r.tilted && r.distance < 100_000 ? 60 : 0))
    }
}
