// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FEGlobe

/// Connects the app to FEGlobe: fly requests and the 3D models go in, the camera and the loading status come out.
struct EngineGlobe: View {
    @ObservedObject var model: AtlasModel
    @ObservedObject var catalog: MeshCatalog
    @AppStorage("terrain") private var terrain = true
    @AppStorage("sunlight") private var sunlight = true
    @AppStorage("placeNames") private var placeNames = true
    @State private var camera = GlobeCamera()
    @State private var status = GlobeStatus()

    private static let modelService = URL(string: "https://mesh.flowsearch.org/api/model")!

    /// the models that cover the place in the middle: the photo mesh of a city, else the most viewed Esri layers there
    private var models: [GlobeModel] {
        let c = model.camera
        guard c.distance < 9000 else { return [] }
        return catalog.models(latitude: c.latitude, longitude: c.longitude, limit: 3).compactMap { m in
            let owner = m.owner.map { " · \($0)" } ?? ""
            if m.is3DTiles { return GlobeModel(id: m.id, name: m.title + owner, kind: .modelService(Self.modelService)) }
            guard let url = URL(string: m.url) else { return nil }
            return GlobeModel(id: m.id, name: m.title + owner, kind: .sceneLayer(url))
        }
    }

    var body: some View {
        FEGlobeView(camera: $camera, options: GlobeOptions(terrain: terrain, sunlight: sunlight, placeNames: placeNames),
                    models: models, status: $status)
            .overlay(alignment: .bottomLeading) { information }
            .onAppear {
                let c = model.camera
                camera = GlobeCamera(latitude: c.latitude, longitude: c.longitude, distance: c.distance, heading: c.heading,
                                     tilt: model.tilted && c.distance < 100_000 ? 55 : 0)
            }
            .onChange(of: model.request) { _, request in
                guard let r = request else { return }
                camera = GlobeCamera(latitude: r.latitude, longitude: r.longitude, distance: r.distance, heading: r.heading,
                                     tilt: r.tilted && r.distance < 100_000 ? 55 : 0)
            }
            .onChange(of: camera) { _, c in
                model.camera = CameraState(latitude: c.latitude, longitude: c.longitude, distance: c.distance, heading: c.heading)
            }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 4) {
            if status.offline { badge("No internet connection", symbol: "wifi.slash") }
            if let name = status.loadingModel {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading \(name)").lineLimit(2)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else if let name = status.shownModel {
                badge(name, symbol: "cube.fill")
            } else if let error = status.modelError {
                badge(error, symbol: "exclamationmark.triangle")
            }
            Text("\(GlobeImagery.versatiles.attribution). Night lights and names: NASA GIBS. Terrain: Mapzen, SRTM.")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.8))
                .shadow(color: .black, radius: 2)
        }
        .font(.caption2)
        .padding(.leading, 10)
        .padding(.bottom, 8)
        .padding(.trailing, 80)
    }

    private func badge(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .lineLimit(3)
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
