// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FEGlobe

/// Connects the app to FEGlobe: fly requests and the 3D models go in, the camera and the loading status come out.
struct EngineGlobe: View {
    @ObservedObject var model: AtlasModel
    @ObservedObject var catalog: MeshCatalog
    @AppStorage("terrain") private var terrain = true
    @AppStorage("sunlight") private var sunlight = false
    @State private var showCredits = false
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
            if status.loadingModel != nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading 3D")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }
            // one short line, as on the well-known globes; a tap shows all credits (and who owns the 3D model on the screen)
            Button {
                showCredits = true
            } label: {
                Text("© \(status.shownModel ?? "Official aerial photos · Sentinel-2 by EOX · NASA · terrain contributors")  ⓘ")
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black, radius: 2)
            }
        }
        .font(.caption2)
        .padding(.leading, 10)
        .padding(.bottom, 8)
        .padding(.trailing, 80)
        .sheet(isPresented: $showCredits) {
            NavigationStack {
                LicencesView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCredits = false } } }
                    .safeAreaInset(edge: .bottom) {
                        if let name = status.shownModel ?? status.modelError {
                            Text(name).font(.footnote).padding().frame(maxWidth: .infinity).background(.regularMaterial)
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func badge(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .lineLimit(3)
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
