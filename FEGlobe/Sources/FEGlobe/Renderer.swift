// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Metal
import MetalKit
import ImageIO
import UIKit
import simd

/// What the globe shows.
public struct GlobeOptions: Equatable, Sendable {
    public var terrain: Bool
    public var sunlight: Bool
    public var placeNames: Bool

    public init(terrain: Bool = true, sunlight: Bool = true, placeNames: Bool = true) {
        self.terrain = terrain
        self.sunlight = sunlight
        self.placeNames = placeNames
    }
}

/// What the globe reports to the app.
public struct GlobeStatus: Equatable, Sendable {
    public var offline = false
    public var loadingModel: String?
    public var shownModel: String?
    public var modelError: String?
    public init() {}
}

private struct Vertex {
    var x: Float, y: Float, z: Float
    var u: Float, v: Float
}

private struct Uniforms {
    var viewProjection: simd_float4x4
    var offset: SIMD4<Float>
    var centre: SIMD4<Float>
    var uvBase: SIMD4<Float>
    var uvNight: SIMD4<Float>
    var uvNames: SIMD4<Float>
    var sun: SIMD4<Float>
}

private struct Mesh {
    let buffer: MTLBuffer
    let centre: SIMD3<Double>
    let elevationZoom: Int
}

private struct Flight {
    let from: GlobeCamera
    let to: GlobeCamera
    let start: Date
    let duration: Double
}

private struct PreparedPiece: @unchecked Sendable {
    let vertices: [Vertex]
    let indices: [UInt32]
    let picture: Pixels?
}

private struct DrawnPiece {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let count: Int
    let picture: MTLTexture
}

private struct DrawnModel {
    let id: String
    let latitude: Double
    let longitude: Double
    let anchor: SIMD3<Double>
    let pieces: [DrawnPiece]
}

/// Draws the globe: tiles of the map are bent onto the sphere and lifted by the terrain, finer where the eye is near; 3D models stand on it.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    private static let grid = 16
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let groundPipeline: MTLRenderPipelineState
    private let modelPipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private let indices: MTLBuffer
    private let indexCount: Int
    private let black: MTLTexture
    private let clear: MTLTexture
    private let grey: MTLTexture
    private let base: TileCache<MTLTexture>
    private let night: TileCache<MTLTexture>
    private let names: TileCache<MTLTexture>
    private let elevation: TileCache<Elevation>
    private var meshes: [TileKey: Mesh] = [:]
    private var flight: Flight?
    private var ground = 0.0
    private var dirty = 3
    private var lastSun = Date.distantPast
    private var observer: NSObjectProtocol?

    private var wantedModels: [GlobeModel] = []
    private var drawn: DrawnModel?
    private var modelTask: Task<Void, Never>?
    private var tried: (key: String, latitude: Double, longitude: Double)?

    private(set) var camera = GlobeCamera()
    private(set) var status = GlobeStatus()
    var options = GlobeOptions() {
        didSet {
            if options != oldValue {
                meshes.removeAll()
                redraw()
            }
        }
    }
    var onChange: ((GlobeCamera) -> Void)?
    var onStatus: ((GlobeStatus) -> Void)?

    init?(view: MTKView, imagery: GlobeImagery) {
        guard let device = view.device, let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module) else { return nil }
        self.device = device
        self.queue = queue
        func pipeline(_ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "fe_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            d.rasterSampleCount = view.sampleCount
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        let depthDescription = MTLDepthStencilDescriptor()
        depthDescription.depthCompareFunction = .less
        depthDescription.isDepthWriteEnabled = true
        let list = Self.makeIndices()
        func solid(_ rgba: [UInt8]) -> MTLTexture? { Pixels(width: 1, height: 1, bytes: rgba).texture(device) }
        guard let g = pipeline("fe_ground"), let m = pipeline("fe_model"), let depth = device.makeDepthStencilState(descriptor: depthDescription),
              let indices = device.makeBuffer(bytes: list, length: list.count * 2),
              let black = solid([0, 0, 0, 255]), let clear = solid([0, 0, 0, 0]), let grey = solid([150, 155, 160, 255]) else { return nil }
        groundPipeline = g
        modelPipeline = m
        self.depth = depth
        self.indices = indices
        indexCount = list.count
        self.black = black
        self.clear = clear
        self.grey = grey
        let box = Box(device)
        base = TileCache(imagery: imagery, limit: 260) { Pixels.decode($0)?.texture(box.value) }
        night = TileCache(imagery: .nightLights, limit: 80) { Pixels.decode($0)?.texture(box.value) }
        names = TileCache(imagery: .placeNames, limit: 120) { Pixels.decode($0, brightnessIsAlpha: true)?.texture(box.value) }
        elevation = TileCache(imagery: Elevation.source, limit: 120) { Elevation.decode($0) }
        super.init()
        base.onArrival = { [weak self] in self?.redraw() }
        night.onArrival = { [weak self] in self?.redraw() }
        names.onArrival = { [weak self] in self?.redraw() }
        elevation.onArrival = { [weak self] in self?.redraw() }
        base.onFailure = { [weak self] offline in self?.report { $0.offline = offline } }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.freeMemory() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        modelTask?.cancel()
    }

    func redraw() { dirty = 3 }

    private func report(_ change: (inout GlobeStatus) -> Void) {
        var s = status
        change(&s)
        if s != status {
            status = s
            onStatus?(s)
        }
    }

    private func freeMemory() {
        meshes.removeAll()
        base.clear()
        night.clear()
        names.clear()
        elevation.clear()
        removeModel()
        redraw()
    }

    // MARK: the camera

    func set(_ new: GlobeCamera) {
        flight = nil
        camera = new
        camera.clamp()
        redraw()
        onChange?(camera)
    }

    /// moves there smoothly, rising on the way when the place is far
    func fly(to target: GlobeCamera, duration: Double = 2) {
        var to = target
        to.clamp()
        flight = Flight(from: camera, to: to, start: Date(), duration: duration)
        redraw()
    }

    private func advance() {
        guard let f = flight else { return }
        let raw = min(1, Date().timeIntervalSince(f.start) / f.duration)
        let t = raw * raw * (3 - 2 * raw)
        var c = f.to
        let turn = (f.to.longitude - f.from.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        let spin = (f.to.heading - f.from.heading + 540).truncatingRemainder(dividingBy: 360) - 180
        c.latitude = f.from.latitude + (f.to.latitude - f.from.latitude) * t
        c.longitude = f.from.longitude + turn * t
        c.heading = f.from.heading + spin * t
        c.tilt = f.from.tilt + (f.to.tilt - f.from.tilt) * t
        let apart = simd_distance(GlobeCamera.point(latitude: f.from.latitude, longitude: f.from.longitude),
                                  GlobeCamera.point(latitude: f.to.latitude, longitude: f.to.longitude))
        c.distance = exp(log(f.from.distance) + (log(f.to.distance) - log(f.from.distance)) * t) + sin(.pi * t) * apart * 0.7
        c.clamp()
        camera = c
        if raw >= 1 { flight = nil }
        redraw()
        onChange?(camera)
    }

    private func height(latitude: Double, longitude: Double, zoom: Int) -> Double? {
        let (key, u, v) = Geodesy.tile(latitude: latitude, longitude: longitude, zoom: zoom)
        guard let found = elevation.best(key) else { return nil }
        let (e, part) = found
        return e.sample(Double(part.x) + u * Double(part.z), Double(part.y) + v * Double(part.w))
    }

    // MARK: the tiles

    private static func makeIndices() -> [UInt16] {
        let n = grid
        var list: [UInt16] = []
        for row in 0..<n {
            for column in 0..<n {
                let a = UInt16(row * (n + 1) + column), b = a + 1, c = a + UInt16(n + 1), d = c + 1
                list += [a, c, b, b, c, d]
            }
        }
        // the skirts: a strip hanging down from every edge hides the cracks between tiles of different detail
        let first = (n + 1) * (n + 1)
        let edges: [(Int) -> Int] = [{ $0 }, { n * (n + 1) + $0 }, { $0 * (n + 1) }, { $0 * (n + 1) + n }]
        for (e, edge) in edges.enumerated() {
            for i in 0..<n {
                let a = UInt16(edge(i)), b = UInt16(edge(i + 1))
                let c = UInt16(first + e * (n + 1) + i), d = c + 1
                list += [a, c, b, b, c, d]
            }
        }
        return list
    }

    private func mesh(_ key: TileKey) -> Mesh? {
        let heights = options.terrain ? elevation.best(key) : nil
        var elevationZoom = -1
        if let found = heights { elevationZoom = key.z - Int((-log2(Double(found.1.z))).rounded()) }
        if let m = meshes[key], m.elevationZoom >= elevationZoom { return m }
        let n = Self.grid
        let centre = GlobeCamera.point(latitude: Geodesy.tileLatitude(row: Double(key.y) + 0.5, zoom: key.z),
                                       longitude: Geodesy.tileLongitude(column: Double(key.x) + 0.5, zoom: key.z))
        let skirt = max(30, 2 * .pi * GlobeCamera.radius / Double(1 << key.z) * 0.03)
        func vertex(_ row: Int, _ column: Int, drop: Double) -> Vertex {
            let u = Double(column) / Double(n), v = Double(row) / Double(n)
            var lat = Geodesy.tileLatitude(row: Double(key.y) + v, zoom: key.z)
            // the map ends at 85 degrees: the first and the last row reach to the poles
            if key.y == 0 && row == 0 { lat = 90 }
            if key.y == (1 << key.z) - 1 && row == n { lat = -90 }
            let lon = Geodesy.tileLongitude(column: Double(key.x) + u, zoom: key.z)
            var h = 0.0
            if let found = heights {
                let (e, part) = found
                h = e.sample(Double(part.x) + u * Double(part.z), Double(part.y) + v * Double(part.w))
            }
            let p = GlobeCamera.point(latitude: lat, longitude: lon) * (1 + (h - drop) / GlobeCamera.radius) - centre
            return Vertex(x: Float(p.x), y: Float(p.y), z: Float(p.z), u: Float(u), v: Float(v))
        }
        var vertices: [Vertex] = []
        vertices.reserveCapacity((n + 1) * (n + 5))
        for row in 0...n { for column in 0...n { vertices.append(vertex(row, column, drop: 0)) } }
        for i in 0...n { vertices.append(vertex(0, i, drop: skirt)) }
        for i in 0...n { vertices.append(vertex(n, i, drop: skirt)) }
        for i in 0...n { vertices.append(vertex(i, 0, drop: skirt)) }
        for i in 0...n { vertices.append(vertex(i, n, drop: skirt)) }
        guard let buffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Vertex>.stride) else { return nil }
        if meshes.count > 600 { meshes.removeAll() }
        let m = Mesh(buffer: buffer, centre: centre, elevationZoom: elevationZoom)
        meshes[key] = m
        return m
    }

    /// the tiles that the picture needs
    private func visibleTiles(eye: SIMD3<Double>, forward: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>, aspect: Double, height: Double) -> [TileKey] {
        let radius = GlobeCamera.radius
        let eyeLength = simd_length(eye)
        let horizon = acos(min(1, radius / max(radius, eyeLength)))
        let tanY = tan(GlobeCamera.fieldOfView / 2), tanX = tanY * aspect
        let pixels = height / (2 * tanY)
        var found: [TileKey] = []
        var open: [TileKey] = [TileKey(z: 1, x: 0, y: 0), TileKey(z: 1, x: 1, y: 0), TileKey(z: 1, x: 0, y: 1), TileKey(z: 1, x: 1, y: 1)]
        var next = 0
        while next < open.count, found.count < 220 {
            let key = open[next]
            next += 1
            let north = Geodesy.tileLatitude(row: Double(key.y), zoom: key.z), south = Geodesy.tileLatitude(row: Double(key.y + 1), zoom: key.z)
            let lat = Geodesy.tileLatitude(row: Double(key.y) + 0.5, zoom: key.z)
            let lon = Geodesy.tileLongitude(column: Double(key.x) + 0.5, zoom: key.z)
            let centre = GlobeCamera.point(latitude: lat, longitude: lon)
            let west = Geodesy.tileLongitude(column: Double(key.x), zoom: key.z)
            var reach = max(simd_distance(centre, GlobeCamera.point(latitude: north, longitude: west)),
                            simd_distance(centre, GlobeCamera.point(latitude: south, longitude: west)))
            if key.z <= 2 { reach = radius * 1.5 }
            if key.z > 2 {
                let angle = acos(max(-1, min(1, simd_dot(centre / radius, eye / eyeLength))))
                if angle > horizon + 2 * asin(min(1, reach / (2 * radius))) + 0.03 { continue } // behind the horizon
                let rel = centre - eye
                let ahead = simd_dot(rel, forward)
                let slack = reach + 4000 // mountains reach into the picture
                if ahead < -slack { continue }
                if abs(simd_dot(rel, right)) > ahead * tanX + slack * (1 + tanX) { continue }
                if abs(simd_dot(rel, up)) > ahead * tanY + slack * (1 + tanY) { continue }
            }
            let size = 2 * .pi * radius * cos(lat * .pi / 180) / Double(1 << key.z)
            let away = max(simd_distance(eye, centre) - reach * 0.7, eyeLength - radius - ground)
            if key.z < base.maxZoom && (key.z < 3 || size / max(1, away) * pixels > 420) {
                for dy in 0...1 {
                    for dx in 0...1 { open.append(TileKey(z: key.z + 1, x: key.x * 2 + dx, y: key.y * 2 + dy)) }
                }
            } else {
                found.append(key)
            }
        }
        found.append(contentsOf: open[next...]) // when there are too many, the rest stays coarse
        return found
    }

    // MARK: the models

    func setModels(_ models: [GlobeModel]) {
        if models != wantedModels {
            wantedModels = models
            tried = nil
            if let drawn, !models.contains(where: { $0.id == drawn.id }) { removeModel() }
            redraw()
        }
    }

    private func removeModel() {
        modelTask?.cancel()
        modelTask = nil
        drawn = nil
        tried = nil
        report {
            $0.loadingModel = nil
            $0.shownModel = nil
            $0.modelError = nil
        }
    }

    private func metres(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        simd_distance(GlobeCamera.point(latitude: a.0, longitude: a.1), GlobeCamera.point(latitude: b.0, longitude: b.1))
    }

    private func updateModels() {
        if camera.distance > 9000 || wantedModels.isEmpty {
            if drawn != nil || modelTask != nil { removeModel() }
            return
        }
        guard camera.distance < 4500, flight == nil, modelTask == nil else { return }
        let here = (camera.latitude, camera.longitude)
        let key = wantedModels.map(\.id).joined(separator: "|")
        if let tried, tried.key == key, metres(here, (tried.latitude, tried.longitude)) < 180 { return }
        // the height of the ground has to be known to set the model on it
        guard let level = options.terrain ? height(latitude: here.0, longitude: here.1, zoom: 13) : 0 else { return }
        tried = (key, here.0, here.1)
        let candidates = Array(wantedModels.prefix(3))
        modelTask = Task { [weak self] in
            var failure: String?
            for model in candidates {
                self?.report {
                    $0.loadingModel = model.name
                    $0.modelError = nil
                }
                do {
                    let pieces = try await ModelLoader.load(model, latitude: here.0, longitude: here.1, radius: 260)
                    let prepared = await Task.detached(priority: .userInitiated) {
                        Box(Renderer.prepare(pieces, latitude: here.0, longitude: here.1, level: level))
                    }.value.value
                    try Task.checkCancellation()
                    self?.show(prepared, model: model, latitude: here.0, longitude: here.1)
                    failure = nil
                    break
                } catch is CancellationError {
                    return
                } catch {
                    failure = "\(model.name): \(error.localizedDescription)"
                }
            }
            if Task.isCancelled { return }
            self?.report {
                $0.loadingModel = nil
                $0.modelError = failure
            }
            self?.modelTask = nil
        }
    }

    /// turns the pieces (x east, y up, z south) into vertices on the sphere, standing on the terrain
    private nonisolated static func prepare(_ pieces: [ModelPiece], latitude: Double, longitude: Double, level: Double) -> [PreparedPiece] {
        var heights: [Float] = []
        for p in pieces {
            for v in stride(from: 0, to: p.positions.count - 2, by: 9) where abs(p.positions[v]) < 90 && abs(p.positions[v + 2]) < 90 {
                heights.append(p.positions[v + 1])
            }
        }
        if heights.count < 20 { heights = pieces.flatMap { p in stride(from: 0, to: p.positions.count - 2, by: 9).map { p.positions[$0 + 1] } } }
        heights.sort()
        let floor = heights.isEmpty ? 0 : Double(heights[heights.count * 6 / 100])
        let lift = level + 1.5 - floor
        let (east, up, north) = Geodesy.basis(latitude: latitude, longitude: longitude)
        return pieces.compactMap { p in
            let count = p.positions.count / 3
            guard count > 0, !p.indices.isEmpty, p.indices.allSatisfy({ $0 < UInt32(count) }) else { return nil }
            let textured = p.uv.count >= count * 2
            let vertices = (0..<count).map { i -> Vertex in
                let x = Double(p.positions[i * 3]), y = Double(p.positions[i * 3 + 1]) + lift, z = Double(p.positions[i * 3 + 2])
                let q = east * x + up * y - north * z
                return Vertex(x: Float(q.x), y: Float(q.y), z: Float(q.z), u: textured ? p.uv[i * 2] : 0, v: textured ? p.uv[i * 2 + 1] : 0)
            }
            return PreparedPiece(vertices: vertices, indices: p.indices, picture: textured ? p.picture.flatMap { smallPicture($0) } : nil)
        }
    }

    /// a picture of a model, at most 512 pixels on a side (the memory of a phone)
    private nonisolated static func smallPicture(_ data: Data) -> Pixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary) else { return nil }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Pixels(width: w, height: h, bytes: bytes) : nil
    }

    private func show(_ pieces: [PreparedPiece], model: GlobeModel, latitude: Double, longitude: Double) {
        let ready = pieces.compactMap { p -> DrawnPiece? in
            guard let v = device.makeBuffer(bytes: p.vertices, length: p.vertices.count * MemoryLayout<Vertex>.stride),
                  let i = device.makeBuffer(bytes: p.indices, length: p.indices.count * 4) else { return nil }
            return DrawnPiece(vertices: v, indices: i, count: p.indices.count, picture: p.picture?.texture(device) ?? grey)
        }
        drawn = DrawnModel(id: model.id, latitude: latitude, longitude: longitude,
                           anchor: GlobeCamera.point(latitude: latitude, longitude: longitude), pieces: ready)
        report { $0.shownModel = model.name }
        redraw()
    }

    // MARK: drawing

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { redraw() }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        advance()
        updateModels()
        if let level = options.terrain ? height(latitude: camera.latitude, longitude: camera.longitude, zoom: 11) : 0, abs(level - ground) > 0.5 {
            ground += (level - ground) * 0.15
            redraw()
        }
        if Date().timeIntervalSince(lastSun) > 30 {
            lastSun = Date()
            redraw()
        }
        // nothing changed: the last picture stays, which saves the battery
        guard dirty > 0 else { return }
        guard view.drawableSize.height > 0, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        dirty -= 1
        for cache in [base, night, names] { cache.frame += 1 }
        elevation.frame += 1
        let (eye, forward, right, up) = camera.frame(ground: ground)
        let aspect = Double(view.drawableSize.width / view.drawableSize.height)
        let altitude = simd_length(eye) - GlobeCamera.radius - ground
        let near = Float(max(2, altitude * 0.15))
        let far = Float(simd_length(eye) + GlobeCamera.radius)
        let ys = Float(1 / tan(GlobeCamera.fieldOfView / 2)), xs = ys / Float(aspect), zs = far / (near - far)
        let projection = simd_float4x4(rows: [SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, near * zs), SIMD4(0, 0, -1, 0)])
        let r = SIMD3<Float>(right), u = SIMD3<Float>(up), f = SIMD3<Float>(forward)
        let turn = simd_float4x4(rows: [SIMD4(r.x, r.y, r.z, 0), SIMD4(u.x, u.y, u.z, 0), SIMD4(-f.x, -f.y, -f.z, 0), SIMD4(0, 0, 0, 1)])
        let viewProjection = projection * turn
        let sun = SIMD3<Float>(Geodesy.sunDirection(Date()))
        // near the ground the map is always lit: a city at night would be black
        let lit: Float = options.sunlight ? Float(min(1, max(0, (camera.distance - 80_000) / 1_500_000))) : 0
        let whole = SIMD4<Float>(0, 0, 1, 1)

        encoder.setDepthStencilState(depth)
        encoder.setRenderPipelineState(groundPipeline)
        for key in visibleTiles(eye: eye, forward: forward, right: right, up: up, aspect: aspect, height: Double(view.drawableSize.height)) {
            guard let found = base.best(key), let m = mesh(key) else { continue }
            let (picture, uv) = found
            let dark = lit > 0 ? night.best(key) : nil
            let (namesKey, namesPart) = key.clamped(to: names.maxZoom)
            // stretched far beyond their finest level the names would be giant letters: not shown there
            let label = options.placeNames && key.z <= names.maxZoom + 1 ? names.value(namesKey) : nil
            let offset = SIMD3<Float>(m.centre - eye), centre = SIMD3<Float>(m.centre)
            var uniforms = Uniforms(viewProjection: viewProjection, offset: SIMD4(offset, 0), centre: SIMD4(centre, 0), uvBase: uv,
                                    uvNight: dark?.1 ?? whole, uvNames: label == nil ? whole : namesPart, sun: SIMD4(sun, lit))
            encoder.setVertexBuffer(m.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(picture, index: 0)
            encoder.setFragmentTexture(dark?.0 ?? black, index: 1)
            encoder.setFragmentTexture(label ?? clear, index: 2)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16, indexBuffer: indices, indexBufferOffset: 0)
        }
        if let model = drawn {
            encoder.setRenderPipelineState(modelPipeline)
            let offset = SIMD3<Float>(model.anchor - eye), centre = SIMD3<Float>(model.anchor)
            var uniforms = Uniforms(viewProjection: viewProjection, offset: SIMD4(offset, 0), centre: SIMD4(centre, 0), uvBase: whole,
                                    uvNight: whole, uvNames: whole, sun: SIMD4(sun, 0))
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            for piece in model.pieces {
                encoder.setVertexBuffer(piece.vertices, offset: 0, index: 0)
                encoder.setFragmentTexture(piece.picture, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: piece.count, indexType: .uint32, indexBuffer: piece.indices, indexBufferOffset: 0)
            }
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}
