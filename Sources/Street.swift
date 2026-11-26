// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import SceneKit
import MapKit

/// One street photo of Panoramax.
struct StreetPicture: Identifiable, Equatable, Sendable {
    var id: String { address }
    let address: String
    let latitude: Double
    let longitude: Double
    let image: URL
    let full: Bool
    let author: String
    let date: String
    let licence: String
    let previous: String?
    let next: String?
}

/// A stretch of street that has photos.
typealias StreetLine = [CLLocationCoordinate2D]

/// Where there are photos: streets when near; from far away dots, one for each area that has some.
struct Coverage: Sendable {
    var lines: [StreetLine] = []
    var dots: [CLLocationCoordinate2D] = []
    var isEmpty: Bool { lines.isEmpty && dots.isEmpty }
}

/// The coverage tiles wanted for a camera: their zoom level and the middle one.
struct TileView: Equatable, Sendable {
    let zoom: Int
    let x: Int
    let y: Int
}

enum Panoramax {
    static let api = "https://api.panoramax.xyz/api"
    /// the camera must be this near, in metres, for a tap to open a photo; from farther away it flies closer
    static let near = 4_000.0
    /// below this tile level the tiles hold areas (a grid), from it on streets
    private static let streetsFrom = 7

    private static func download(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Atlas-iOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func picture(_ item: [String: Any]) -> StreetPicture? {
        guard let properties = item["properties"] as? [String: Any],
              let geometry = item["geometry"] as? [String: Any], let at = geometry["coordinates"] as? [Double], at.count >= 2,
              let assets = item["assets"] as? [String: Any],
              let asset = (assets["sd"] ?? assets["hd"]) as? [String: Any],
              let image = (asset["href"] as? String).flatMap(URL.init(string:)) else { return nil }
        var found: [String: String] = [:]
        for link in item["links"] as? [[String: Any]] ?? [] {
            guard let rel = link["rel"] as? String, let href = link["href"] as? String else { continue }
            found[rel] = href.hasPrefix("/") ? "https://api.panoramax.xyz" + href : href
        }
        guard let own = found["self"] else { return nil }
        let view = (properties["pers:interior_orientation"] as? [String: Any])?["field_of_view"] as? Double ?? 0
        return StreetPicture(address: own, latitude: at[1], longitude: at[0], image: image, full: view >= 360,
                             author: properties["geovisio:producer"] as? String ?? "Panoramax contributor",
                             date: String((properties["datetime"] as? String ?? "").prefix(10)),
                             licence: properties["license"] as? String ?? "", previous: found["prev"], next: found["next"])
    }

    static func load(_ address: String) async -> StreetPicture? {
        guard let data = try? await download(address),
              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return picture(item)
    }

    /// the photo nearest to a tapped place (a full round one wins when it is about as near), or nil
    static func nearest(latitude: Double, longitude: Double, reach: Double) async throws -> StreetPicture? {
        let dLat = reach / 110_574
        let dLon = reach / (111_320 * max(0.1, cos(latitude * .pi / 180)))
        let data = try await download("\(api)/search?limit=100&bbox=\(longitude - dLon),\(latitude - dLat),\(longitude + dLon),\(latitude + dLat)")
        let answer = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        func away(_ p: StreetPicture) -> Double {
            let y = (p.latitude - latitude) * 110_574
            let x = (p.longitude - longitude) * 111_320 * cos(latitude * .pi / 180)
            return hypot(x, y) * (p.full ? 0.6 : 1)
        }
        return (answer?["features"] as? [[String: Any]] ?? []).compactMap(picture).min { away($0) < away($1) }
    }

    static func view(latitude: Double, longitude: Double, distance: Double) -> TileView {
        let level = log2(40_000_000 * max(0.1, cos(latitude * .pi / 180)) / max(100, distance)) + 1
        let zoom = min(14, max(2, Int(level)))
        let size = Double(1 << zoom)
        if size <= 4 { return TileView(zoom: zoom, x: 0, y: 0) } // far out: the whole world
        let safe = min(85, max(-85, latitude))
        return TileView(zoom: zoom, x: Int((longitude + 180) / 360 * size), y: Int((1 - asinh(tan(safe * .pi / 180)) / .pi) / 2 * size))
    }

    /// where there are photos around the middle of the view; all tiles are asked at the same time
    /// (the system keeps its own copy of answers, so moving back asks little twice)
    static func coverage(_ view: TileView) async -> Coverage {
        let size = 1 << view.zoom
        var wanted: [(Int, Int)] = []
        if size <= 4 {
            for x in 0..<size { for y in 0..<size { wanted.append((x, y)) } }
        } else {
            for dx in -2...2 {
                for dy in -2...2 where view.y + dy >= 0 && view.y + dy < size {
                    wanted.append(((view.x + dx + size) % size, view.y + dy))
                }
            }
        }
        return await withTaskGroup(of: Coverage.self) { group in
            for (x, y) in wanted {
                group.addTask {
                    guard let data = try? await download("\(api)/map/\(view.zoom)/\(x)/\(y).mvt") else { return Coverage() }
                    return read([UInt8](data), zoom: view.zoom, tileX: x, tileY: y)
                }
            }
            var all = Coverage()
            for await part in group {
                all.lines += part.lines
                all.dots += part.dots
            }
            return all
        }
    }

    // MARK: the covered streets, read from the vector tiles (Mapbox Vector Tile format)

    private struct Reader {
        let bytes: [UInt8]
        var at: Int
        let end: Int
        var more: Bool { at < end }
        mutating func number() -> Int {
            var result = 0, shift = 0
            while at < end {
                let c = bytes[at]
                at += 1
                if shift < 63 { result |= Int(c & 127) << shift }
                if c < 128 { break }
                shift += 7
            }
            return result
        }
        /// a part with its length in front
        mutating func part() -> Reader {
            let length = max(0, min(number(), end - at))
            let r = Reader(bytes: bytes, at: at, end: at + length)
            at += length
            return r
        }
        mutating func skip(_ kind: Int) {
            switch kind {
            case 0: _ = number()
            case 1: at += 8
            case 2: _ = part()
            default: at += 4
            }
        }
    }

    /// is this value of a tile a number above zero?
    private static func positive(_ value: Reader) -> Bool {
        var value = value
        while value.more {
            let k = value.number()
            switch k >> 3 {
            case 4, 5: return value.number() > 0
            case 6:
                let n = value.number()
                return (n >> 1) ^ -(n & 1) > 0
            case 2, 3:
                let count = k >> 3 == 2 ? 4 : 8
                guard value.at + count <= value.bytes.count else { return false }
                var bits: UInt64 = 0
                for i in 0..<count { bits |= UInt64(value.bytes[value.at + i]) << (8 * i) }
                return count == 4 ? Float(bitPattern: UInt32(truncatingIfNeeded: bits)) > 0 : Double(bitPattern: bits) > 0
            default: value.skip(k & 7)
            }
        }
        return false
    }

    private static func read(_ data: [UInt8], zoom: Int, tileX: Int, tileY: Int) -> Coverage {
        var result = Coverage()
        let wanted = zoom < streetsFrom ? "grid" : "sequences"
        var tile = Reader(bytes: data, at: 0, end: data.count)
        let size = Double(1 << zoom)
        while tile.more {
            let key = tile.number()
            if key >> 3 != 3 { tile.skip(key & 7); continue }
            var layer = tile.part()
            var name = ""
            var extent = 4096
            var features: [Reader] = []
            var keys: [String] = []
            var values: [Reader] = []
            while layer.more {
                let k = layer.number()
                switch k >> 3 {
                case 1:
                    let p = layer.part()
                    name = String(decoding: data[p.at..<p.end], as: UTF8.self)
                case 2: features.append(layer.part())
                case 3:
                    let p = layer.part()
                    keys.append(String(decoding: data[p.at..<p.end], as: UTF8.self))
                case 4: values.append(layer.part())
                case 5: extent = layer.number()
                default: layer.skip(k & 7)
                }
            }
            if name != wanted { continue }
            // an area of the grid counts only if its "coef" says that it has photos
            let coef = keys.firstIndex(of: "coef")
            let full = values.map(positive)
            for var feature in features {
                var empty = false
                while feature.more {
                    let k = feature.number()
                    if k >> 3 == 2 {
                        var tags = feature.part()
                        while tags.more {
                            let key = tags.number(), value = tags.number()
                            if key == coef && value < full.count && !full[value] { empty = true }
                        }
                        continue
                    }
                    if k >> 3 != 4 { feature.skip(k & 7); continue }
                    // the geometry: "move to" starts a line, "line to" goes on; steps are relative
                    var g = feature.part()
                    var x = 0, y = 0
                    var line: StreetLine = []
                    while g.more {
                        let command = g.number()
                        let what = command & 7
                        if what != 1 && what != 2 { continue }
                        for _ in 0..<(command >> 3) where g.more {
                            let a = g.number(), c = g.number()
                            x += (a >> 1) ^ -(a & 1)
                            y += (c >> 1) ^ -(c & 1)
                            if what == 1 {
                                if wanted == "sequences" && line.count > 1 { result.lines.append(line) }
                                line = []
                            }
                            let longitude = (Double(tileX) + Double(x) / Double(extent)) / size * 360 - 180
                            let latitude = atan(sinh(.pi * (1 - 2 * (Double(tileY) + Double(y) / Double(extent)) / size))) * 180 / .pi
                            let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                            // points over the edge of the tile belong to the neighbour
                            if wanted == "grid" && !empty && x >= 0 && x < extent && y >= 0 && y < extent { result.dots.append(point) }
                            line.append(point)
                        }
                    }
                    if wanted == "sequences" && line.count > 1 { result.lines.append(line) }
                }
            }
        }
        return result
    }
}

/// Street view: whether it is on, the blue streets, and the photo or Look Around scene that is open.
@MainActor
final class StreetModel: ObservableObject {
    @Published var on = false
    @Published private(set) var coverage = Coverage()
    @Published private(set) var version = 0
    /// "fly there" for a tap from far away
    var closer: ((Double, Double, Double) -> Void)?
    @Published var status = ""
    @Published var picture: StreetPicture?
    @Published var lookAround: MKLookAroundScene?
    @Published var showLookAround = false

    private var shownView: TileView?
    private var task: Task<Void, Never>?

    /// loads the blue coverage for the camera, at every zoom (only for the map that shows Panoramax)
    func update(_ camera: CameraState, apple: Bool) {
        guard on, !apple else {
            task?.cancel()
            if !coverage.isEmpty { show(Coverage()) }
            shownView = nil
            return
        }
        let view = Panoramax.view(latitude: camera.latitude, longitude: camera.longitude, distance: camera.distance)
        if view == shownView { return }
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let found = await Panoramax.coverage(view)
            if Task.isCancelled { return }
            shownView = found.isEmpty ? nil : view
            show(found)
            status = found.isEmpty ? "No street photos around here." : ""
        }
    }

    /// the visitor tapped the map
    func tapped(latitude: Double, longitude: Double, distance: Double, apple: Bool) {
        guard on else { return }
        if !apple && distance >= Panoramax.near { // from far away a tap flies closer
            closer?(latitude, longitude, max(900, distance / 8))
            return
        }
        status = "Opening…"
        Task {
            if apple {
                let request = MKLookAroundSceneRequest(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                if let scene = try? await request.scene {
                    lookAround = scene
                    showLookAround = true
                    status = ""
                } else {
                    status = "No Look Around there. Try another street."
                }
                return
            }
            do {
                picture = try await Panoramax.nearest(latitude: latitude, longitude: longitude, reach: min(150, max(30, distance * 0.04)))
                status = picture == nil ? "No photo there. Tap on a blue street." : ""
            } catch {
                status = "The photos could not be loaded."
            }
        }
    }

    private func show(_ found: Coverage) {
        coverage = found
        version += 1
    }
}

/// The bar at the bottom while street view is on.
struct StreetBar: View {
    @ObservedObject var street: StreetModel
    let camera: CameraState
    let apple: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: apple ? "binoculars.fill" : "figure.walk").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(apple ? "Tap a street for Look Around" : camera.distance < Panoramax.near ? "Tap a blue street" : "Tap a blue area to fly closer")
                    .font(.headline)
                Text(street.status.isEmpty ? (apple ? "Apple does not say in advance where it exists." : "Photos: Panoramax") : street.status)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button { street.on = false } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                .accessibilityLabel("Close street view")
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

/// A round (360°) photo seen from its middle: drag to look around, pinch to come closer.
private struct RoundPhoto: UIViewRepresentable {
    let image: UIImage

    final class Coordinator: NSObject {
        let camera = SCNNode()
        let material = SCNMaterial()
        private var yaw: Float = 0
        private var pitch: Float = 0

        @objc func drag(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let step = Float((camera.camera?.fieldOfView ?? 75) * .pi / 180) / Float(max(1, view.bounds.height))
            let moved = g.translation(in: view)
            yaw += Float(moved.x) * step
            pitch = min(1.45, max(-1.45, pitch + Float(moved.y) * step))
            camera.eulerAngles = SCNVector3(pitch, yaw, 0)
            g.setTranslation(.zero, in: view)
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let lens = camera.camera else { return }
            lens.fieldOfView = min(100, max(30, lens.fieldOfView / g.scale))
            g.scale = 1
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 96
        let material = context.coordinator.material
        material.lightingModel = .constant
        material.cullMode = .front // seen from inside
        material.diffuse.wrapS = .repeat
        material.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(-1, 1, 1), 1, 0, 0) // not mirrored
        sphere.materials = [material]
        scene.rootNode.addChildNode(SCNNode(geometry: sphere))
        let camera = context.coordinator.camera
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 75
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.backgroundColor = .black
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.material.diffuse.contents = image
    }
}

/// The photo of a street, full screen, with steps along the street.
struct StreetViewer: View {
    @State var picture: StreetPicture
    let close: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                if picture.full {
                    RoundPhoto(image: image).ignoresSafeArea()
                } else {
                    Image(uiImage: image).resizable().scaledToFit().scaleEffect(scale)
                        .gesture(MagnifyGesture().onChanged { scale = min(6, max(1, $0.magnification)) })
                }
            } else if failed {
                Text("The photo could not be loaded.").foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    RoundButton(symbol: "chevron.left", label: "Back to the map", action: close)
                    Spacer()
                }
                Spacer()
                HStack(spacing: 28) {
                    step(picture.next, symbol: "chevron.up", label: "Step forward")
                    step(picture.previous, symbol: "chevron.down", label: "Step back")
                }
                Text("\(picture.date) · \(picture.author) · Panoramax · \(picture.licence)")
                    .font(.caption).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
            }
            .padding(16)
        }
        .task(id: picture.address) {
            failed = false
            image = nil
            scale = 1
            if let (data, _) = try? await URLSession.shared.data(from: picture.image), let loaded = UIImage(data: data) {
                image = loaded
            } else if !Task.isCancelled {
                failed = true
            }
        }
    }

    private func step(_ address: String?, symbol: String, label: String) -> some View {
        RoundButton(symbol: symbol, label: label) {
            guard let address else { return }
            Task { if let found = await Panoramax.load(address) { picture = found } }
        }
        .disabled(address == nil)
        .opacity(address == nil ? 0.35 : 1)
    }
}
