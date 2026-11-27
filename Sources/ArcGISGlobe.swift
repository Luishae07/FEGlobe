// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import ArcGIS

/// One open source of aerial photos (Resources/aerial.json, written by tools/orthocheck from the sources that answered).
struct AerialSource: Decodable {
    let id: String
    let credit: String
    let template: String
    let box: [Double] // west, south, east, north
    let maxZoom: Int

    func covers(latitude: Double, longitude: Double) -> Bool {
        box.count == 4 && longitude >= box[0] && longitude <= box[2] && latitude >= box[1] && latitude <= box[3]
    }

    /// the German states, whose slow map services are not asked directly: mesh.flowsearch.org keeps their tiles on its disk
    private static let kept: Set<String> = ["berlin2024", "saarland-nrw", "brandenburg", "saxony", "thuringia", "saxony-anhalt", "hesse",
                                            "rhineland", "bavaria", "lower-saxony", "mecklenburg"]

    /// the address of one square of the web mercator grid: a tiled service, or a map service (WMS)
    func tileURL(level: Int, row: Int, column: Int) -> URL? {
        var address = template
        if Self.kept.contains(id) {
            address = "https://mesh.flowsearch.org/dop/\(id)/{z}/{x}/{y}.png"
        } else if template.contains("exportImage") { // USGS: the same photos as a tiled service
            address = "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}"
        }
        let edge = 20037508.342789244, size = 2 * edge / Double(1 << level)
        let box = [Double(column) * size - edge, edge - Double(row + 1) * size, Double(column + 1) * size - edge, edge - Double(row) * size]
        address = address.replacingOccurrences(of: "{z}", with: "\(level)").replacingOccurrences(of: "{x}", with: "\(column)")
            .replacingOccurrences(of: "{y}", with: "\(row)")
            .replacingOccurrences(of: "{bbox}", with: box.map { String(format: "%.6f", $0) }.joined(separator: ","))
        return URL(string: address)
    }
}

/// Owns the ArcGIS scene: satellite pictures, terrain, names, and what lies on them close up.
@MainActor
final class SceneHolder: ObservableObject {
    let scene: ArcGIS.Scene
    private var models: [String: Layer] = [:]
    private var names: Layer?
    @Published var shownModels: [String] = []
    @Published var shownPhotos: [String] = []

    private static let sources: [AerialSource] = {
        guard let url = Bundle.main.url(forResource: "aerial", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AerialSource].self, from: data)) ?? []
    }()

    init() {
        // Esri World Imagery (Satellite.swift); below it Sentinel-2 cloudless 2016 by EOX (CC BY 4.0), seen where a picture does not come
        let cloudless = WebTiledLayer(urlTemplate: "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{level}/{row}/{col}.jpg")
        let basemap = Basemap(baseLayer: cloudless)
        basemap.addBaseLayer(Satellite.layer(Self.sources))
        scene = ArcGIS.Scene(basemap: basemap)
        let surface = Surface()
        surface.addElevationSource(ArcGISTiledElevationSource(
            url: URL(string: "https://elevation3d.arcgis.com/arcgis/rest/services/WorldElevation3D/Terrain3D/ImageServer")!))
        scene.baseSurface = surface
        scene.initialViewpoint = Viewpoint(latitude: 30, longitude: 10, scale: 80_000_000)
    }

    // the past: a photo of the year, and buildings raised to their height (measured: orange, guessed: grey)
    private var past: (id: String, layer: Layer)?
    private let measured = SceneHolder.blocks(UIColor(red: 0.94, green: 0.59, blue: 0.24, alpha: 1))
    private let guessed = SceneHolder.blocks(UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1))
    // the streets with photos, in blue, lying on the ground
    private let streetOverlay: GraphicsOverlay = {
        let overlay = GraphicsOverlay()
        overlay.sceneProperties.surfacePlacement = .drapedFlat
        overlay.renderer = SimpleRenderer(symbol: SimpleLineSymbol(style: .solid, color: UIColor(red: 0.1, green: 0.45, blue: 1, alpha: 0.86), width: 5))
        return overlay
    }()
    // and from far away blue dots where there are photos
    private let dotOverlay: GraphicsOverlay = {
        let overlay = GraphicsOverlay()
        overlay.sceneProperties.surfacePlacement = .drapedFlat
        overlay.renderer = SimpleRenderer(symbol: SimpleMarkerSymbol(style: .circle, color: UIColor(red: 0.1, green: 0.45, blue: 1, alpha: 0.82), size: 5))
        return overlay
    }()
    var overlays: [GraphicsOverlay] { [measured, guessed, streetOverlay, dotOverlay] }

    func showCoverage(_ coverage: Coverage) {
        streetOverlay.removeAllGraphics()
        for street in coverage.lines {
            let line = Polyline(points: street.map { Point(x: $0.longitude, y: $0.latitude, spatialReference: .wgs84) })
            streetOverlay.addGraphic(Graphic(geometry: line))
        }
        dotOverlay.removeAllGraphics()
        dotOverlay.addGraphics(coverage.dots.map { Graphic(geometry: Point(x: $0.longitude, y: $0.latitude, spatialReference: .wgs84)) })
    }

    private static func blocks(_ colour: UIColor) -> GraphicsOverlay {
        let overlay = GraphicsOverlay()
        overlay.sceneProperties.surfacePlacement = .relative
        let renderer = SimpleRenderer(symbol: SimpleFillSymbol(style: .solid, color: colour))
        renderer.sceneProperties.extrusionMode = .baseHeight
        renderer.sceneProperties.extrusionExpression = "[h]"
        overlay.renderer = renderer
        return overlay
    }

    func showBuildings(_ buildings: [OldBuilding]) {
        measured.removeAllGraphics()
        guessed.removeAllGraphics()
        for building in buildings {
            let outline = Polygon(points: building.ring.map { Point(x: $0.longitude, y: $0.latitude, spatialReference: .wgs84) })
            (building.measured ? measured : guessed).addGraphic(Graphic(geometry: outline, attributes: ["h": building.height]))
        }
    }

    private static func layer(for picture: OldPicture) -> Layer? {
        if let name = picture.wmsLayer {
            return URL(string: picture.template).map { WMSLayer(url: $0, layerNames: [name]) }
        }
        let address = picture.template.replacingOccurrences(of: "{z}", with: "{level}").replacingOccurrences(of: "{y}", with: "{row}")
            .replacingOccurrences(of: "{x}", with: "{col}")
        // only the levels the service has: nearer than that, ArcGIS enlarges the last one
        let levels = (0...picture.maxLevel).map {
            LevelOfDetail(level: $0, resolution: 156543.03392804097 / pow(2, Double($0)), scale: 591657527.591555 / pow(2, Double($0)))
        }
        let edge = 20037508.342789244
        let info = TileInfo(dpi: 96, format: .jpg, levelsOfDetail: levels, origin: Point(x: -edge, y: edge, spatialReference: .webMercator),
                            spatialReference: .webMercator, tileHeight: 256, tileWidth: 256)
        return WebTiledLayer(urlTemplate: address, tileInfo: info,
                             fullExtent: Envelope(xMin: -edge, yMin: -edge, xMax: edge, yMax: edge, spatialReference: .webMercator))
    }

    /// aerial photos and 3D models for the place looked at; names while they are wanted. year: look into the past
    func show(latitude: Double, longitude: Double, distance: Double, models wanted: [MeshModel], placeNames: Bool, year: Int?) {
        let picture = year.flatMap { History.picture(latitude: latitude, longitude: longitude, year: $0) }
        if past?.id != picture?.id {
            if let old = past { scene.removeOperationalLayer(old.layer) }
            past = nil
            if let picture, let layer = Self.layer(for: picture) {
                // the names are taken off and put on again, so that they lie above the picture
                if let names { scene.removeOperationalLayer(names) }
                names = nil
                past = (picture.id, layer)
                scene.addOperationalLayer(layer)
            }
        }
        // the official photos are only a backup of the satellite pictures (Satellite.swift): their maker is named close up
        let near = distance < 20_000 && picture == nil
            ? Array(Self.sources.filter { $0.covers(latitude: latitude, longitude: longitude) }.prefix(1)) : []
        let ids = Set(wanted.map(\.url))
        for (id, layer) in models where !ids.contains(id) {
            scene.removeOperationalLayer(layer)
            models[id] = nil
        }
        for model in wanted where models[model.url] == nil {
            guard let url = URL(string: model.url) else { continue }
            let layer: Layer = model.is3DTiles ? OGC3DTilesLayer(url: url) : IntegratedMeshLayer(url: url)
            models[model.url] = layer
            scene.addOperationalLayer(layer)
        }
        if placeNames, names == nil {
            let layer = WebTiledLayer(urlTemplate: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/Reference_Labels/default/GoogleMapsCompatible_Level9/{level}/{row}/{col}.png")
            names = layer
            scene.addOperationalLayer(layer)
        }
        names?.isVisible = placeNames && distance > 40_000
        shownModels = wanted.map { "\($0.title)\($0.owner.map { " · \($0)" } ?? "")" }
        let satellite = (picture == nil ? ["Powered by Esri · Esri, Maxar, Earthstar Geographics, and the GIS User Community"] : []) + near.map { "Where Esri fails: \($0.credit)" }
        shownPhotos = satellite + [picture?.credit, year.map { _ in "Buildings: OpenHistoricalMap" }].compactMap { $0 }
    }
}

struct ArcGISGlobe: View {
    @ObservedObject var model: AtlasModel
    @ObservedObject var catalog: MeshCatalog
    @ObservedObject var past: Past
    @ObservedObject var street: StreetModel
    @AppStorage("placeNames") private var placeNames = true
    @StateObject private var holder = SceneHolder()
    @State private var settle = Settle()
    @State private var showCredits = false

    /// waits until the camera has rested for a moment (holding it here does not redraw the screen while the fingers move)
    private final class Settle {
        var task: Task<Void, Never>?
    }

    /// the short credit at the bottom: Esri's comes first while its pictures are shown; everything else is behind the ⓘ
    private var footer: String {
        let photo = holder.shownPhotos.first
        let satellite = photo?.hasPrefix("Powered by Esri") ?? true
        let other = holder.shownModels.first ?? (satellite ? nil : photo)
        return [satellite ? "Powered by Esri" : nil, other].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        SceneViewReader { proxy in
            SceneView(scene: holder.scene, graphicsOverlays: holder.overlays)
                .onSingleTapGesture { screen, _ in
                    guard street.on else { return }
                    Task {
                        guard let ground = try? await proxy.baseSurfaceLocation(fromScreenPoint: screen),
                              let at = GeometryEngine.project(ground, into: .wgs84) else { return }
                        street.tapped(latitude: at.y, longitude: at.x, distance: model.camera.distance, apple: false)
                    }
                }
                .onCameraChanged { new in
                    settle.task?.cancel()
                    settle.task = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        if !Task.isCancelled { update(from: new) }
                    }
                }
                .onChange(of: street.version) { _, _ in holder.showCoverage(street.coverage) }
                .onChange(of: model.request) { _, request in
                    guard let request else { return }
                    Task { await proxy.setViewpointCamera(Self.camera(for: request), duration: 2) }
                }
                .task {
                    // coming from the other map: the same place
                    let c = model.camera
                    if c.distance < 10_000_000 {
                        await proxy.setViewpointCamera(Self.camera(for: FlyRequest(latitude: c.latitude, longitude: c.longitude, distance: c.distance,
                                                                                   heading: c.heading, tilted: model.tilted)), duration: 0)
                    }
                }
        }
        .overlay(alignment: .bottomLeading) {
            Button {
                showCredits = true
            } label: {
                Text("© \(footer)  ⓘ")
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black, radius: 2)
            }
            .padding(.leading, 10)
            .padding(.bottom, 26)
            .padding(.trailing, 80)
        }
        .sheet(isPresented: $showCredits) {
            NavigationStack {
                LicencesView(onScreen: holder.shownModels + holder.shownPhotos)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCredits = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: placeNames) { _, _ in refresh() }
        .onChange(of: catalog.esri.count) { _, _ in refresh() }
        .onChange(of: past.year) { _, _ in refresh() }
        .onChange(of: past.version) { _, _ in holder.showBuildings(past.shown) }
        .onAppear {
            refresh()
            holder.showBuildings(past.shown)
            holder.showCoverage(street.coverage)
        }
    }

    /// the camera that looks at a place from `distance` metres: straight down, or tilted
    private static func camera(for r: FlyRequest) -> Camera {
        let pitch = r.tilted && r.distance < 100_000 ? 55.0 : 0.0
        let angle = pitch * .pi / 180
        let altitude = max(60, r.distance * cos(angle)) + 40
        let back = r.distance * sin(angle)
        let heading = r.heading * .pi / 180
        let latitude = r.latitude - back * cos(heading) / 110_574
        let longitude = r.longitude - back * sin(heading) / (111_320 * max(0.1, cos(r.latitude * .pi / 180)))
        return Camera(latitude: latitude, longitude: longitude, altitude: altitude, heading: r.heading, pitch: pitch, roll: 0)
    }

    /// the place in the middle of the picture, and what belongs there
    private func update(from camera: Camera) {
        let location = camera.location
        let altitude = max(1, location.z ?? 1)
        let pitch = min(80, max(0, camera.pitch)) * .pi / 180
        let ahead = altitude * tan(pitch)
        let heading = camera.heading * .pi / 180
        let latitude = location.y + ahead * cos(heading) / 110_574
        let longitude = location.x + ahead * sin(heading) / (111_320 * max(0.1, cos(location.y * .pi / 180)))
        let state = CameraState(latitude: latitude, longitude: longitude, distance: altitude / max(0.17, cos(pitch)), heading: camera.heading)
        let old = model.camera
        if abs(state.latitude - old.latitude) > 0.001 || abs(state.longitude - old.longitude) > 0.001
            || abs(state.distance - old.distance) > old.distance * 0.1 || abs(state.heading - old.heading) > 2 {
            model.camera = state
            refresh()
        }
    }

    private func refresh() {
        let c = model.camera
        holder.show(latitude: c.latitude, longitude: c.longitude, distance: c.distance,
                    // the 3D models show today: not in the past
                    models: c.distance < 5_000 && past.year == nil ? catalog.models(latitude: c.latitude, longitude: c.longitude, limit: 1) : [],
                    placeNames: placeNames, year: past.year)
    }
}
