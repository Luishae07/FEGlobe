// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Reads the part of an Esri scene layer (I3S integrated mesh) around a place: versions 1.4 to 1.6 (one document per node) and 1.7 and later (node pages),
/// geographic and UTM coordinate systems. Draco-only geometry is not read.
struct SceneLayerReader {
    let base: String
    let latitude: Double
    let longitude: Double
    let radius: Double

    private static let maxNodes = 80
    private static let pixel = 1.4 // refine while the children are needed at this size (metres)

    private struct Selected {
        var centre: [Double]
        var geometry: String
        var picture: String?
        var vertexCount = 0
        var positionParts = 3
        var normalBytes = 0
        var header = 8
        var hasUV = false
    }

    private typealias JSON = [String: Any]

    private func json(_ address: String) async throws -> JSON {
        guard let url = URL(string: address) else { throw ModelError(text: "bad address") }
        let data = try await ModelLoader.fetch(url)
        guard let object = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? JSON else { throw ModelError(text: "not a scene layer") }
        return object
    }

    private func number(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
    private func numbers(_ v: Any?) -> [Double] { (v as? [Any])?.map { number($0) } ?? [] }

    private func parts(_ attribute: JSON?) -> Int { Int(number(attribute?["component"] ?? attribute?["valuesPerElement"])) }

    private func bytes(_ attribute: JSON?) -> Int {
        switch (attribute?["type"] ?? attribute?["valueType"]) as? String {
        case "UInt16", "Int16": return 2
        case "UInt8", "Int8": return 1
        case "Float64", "UInt64", "Int64": return 8
        default: return 4
        }
    }

    func read() async throws -> [ModelPiece] {
        var root = base
        while root.hasSuffix("/") { root.removeLast() }
        root += "/layers/0"
        let layer = try await json(root + "?f=json")
        let reference = layer["spatialReference"] as? JSON
        let wkid = Int(number(reference?["latestWkid"] ?? reference?["wkid"]))
        let utm = Geodesy.utmZone(wkid)
        let geographic = [4326, 4979, 4269, 4258].contains(wkid)
        guard geographic || utm != nil else { throw ModelError(text: "coordinate system \(wkid) is not supported") }
        let metresEast = 111_320 * cos(latitude * .pi / 180), metresNorth = 110_574.0
        let (lat0, lon0) = (latitude, longitude)
        /// (east, north) of a node centre from the asked place
        let local: @Sendable ([Double]) -> (Double, Double) = { c in
            guard c.count >= 2 else { return (1e12, 1e12) }
            var lon = c[0], lat = c[1]
            if let zone = utm { (lon, lat) = Geodesy.utm(x: c[0], y: c[1], zone: zone.0, south: zone.1) }
            return ((lon - lon0) * metresEast, (lat - lat0) * metresNorth)
        }
        let reach = radius * 1.15
        let store = layer["store"] as? JSON
        let version = (store?["version"] as? String ?? "1.6").split(separator: ".").map { Int($0) ?? 0 }
        let paged = version.count >= 2 && (version[0] > 1 || version[1] >= 7)
        var selected: [Selected] = []

        if paged {
            let pagesInfo = layer["nodePages"] as? JSON
            let perPage = Int(number(pagesInfo?["nodesPerPage"]))
            let definitions = layer["geometryDefinitions"] as? [JSON] ?? []
            guard perPage > 0, !definitions.isEmpty else { throw ModelError(text: "no geometry definitions") }
            let squared = (pagesInfo?["lodSelectionMetricType"] as? String ?? "").contains("SQ")
            let sets = layer["textureSetDefinitions"] as? [JSON] ?? []
            var pages: [Int: [JSON]] = [:]
            var open = [0]
            var visited = 0
            while let index = open.popLast(), selected.count < Self.maxNodes, visited < 4000 {
                try Task.checkCancellation()
                let page = index / perPage
                if pages[page] == nil { pages[page] = try await json("\(root)/nodepages/\(page)?f=json")["nodes"] as? [JSON] ?? [] }
                let slot = index - page * perPage
                visited += 1
                guard let nodes = pages[page], slot >= 0, slot < nodes.count else { continue }
                let node = nodes[slot]
                let box = node["obb"] as? JSON
                let centre = numbers(box?["center"]), half = numbers(box?["halfSize"])
                guard centre.count >= 3, half.count >= 3 else { continue }
                let size = (half[0] * half[0] + half[1] * half[1] + half[2] * half[2]).squareRoot()
                let (e, n) = local(centre)
                if hypot(e, n) > size + reach { continue }
                let children = (node["children"] as? [Any])?.map { Int(number($0)) } ?? []
                let threshold = number(node["lodThreshold"])
                let wanted = squared ? .pi * pow(size / Self.pixel, 2) : 2 * size / Self.pixel
                if !children.isEmpty && wanted > threshold {
                    open.append(contentsOf: children)
                    continue
                }
                let mesh = node["mesh"] as? JSON
                guard let geometry = mesh?["geometry"] as? JSON else { continue }
                let definition = Int(number(geometry["definition"]))
                guard definition >= 0, definition < definitions.count,
                      let buffers = definitions[definition]["geometryBuffers"] as? [JSON],
                      let which = buffers.firstIndex(where: { $0["compressedAttributes"] == nil && $0["position"] != nil }) else { continue }
                let buffer = buffers[which]
                let material = mesh?["material"] as? JSON
                var s = Selected(centre: centre, geometry: "\(root)/nodes/\(Int(number(geometry["resource"])))/geometries/\(which)")
                s.vertexCount = Int(number(geometry["vertexCount"]))
                s.positionParts = max(3, parts(buffer["position"] as? JSON))
                s.header = Int(number(buffer["offset"]))
                if let normal = buffer["normal"] as? JSON { s.normalBytes = parts(normal) * bytes(normal) }
                s.hasUV = buffer["uv0"] != nil && material != nil
                if s.hasUV, let material {
                    let set = Int(number(material["definition"]))
                    if set >= 0, set < sets.count,
                       let format = (sets[set]["formats"] as? [JSON])?.first(where: { ["jpg", "png"].contains($0["format"] as? String ?? "") }),
                       let name = format["name"] as? String {
                        s.picture = "\(root)/nodes/\(Int(number(material["resource"])))/textures/\(name)"
                    }
                }
                selected.append(s)
            }
        } else {
            let schema = store?["defaultGeometrySchema"] as? JSON
            let attributes = schema?["vertexAttributes"] as? JSON
            guard let position = attributes?["position"] as? JSON else { throw ModelError(text: "no geometry schema") }
            var frontier = ["root"]
            var documents = 0
            var depth = 0
            while !frontier.isEmpty && depth < 30 && selected.count < Self.maxNodes && documents < 4 * Self.maxNodes {
                try Task.checkCancellation()
                depth += 1
                documents += frontier.count
                var nodes: [JSON] = []
                for id in frontier {
                    if let node = try? await json("\(root)/nodes/\(id)?f=json") { nodes.append(node) }
                }
                var next: [String] = []
                for node in nodes {
                    let sphere = numbers(node["mbs"])
                    guard sphere.count >= 4 else { continue }
                    let (e, n) = local(sphere)
                    if hypot(e, n) > sphere[3] + reach { continue }
                    let children = node["children"] as? [JSON] ?? []
                    if !children.isEmpty, let lod = (node["lodSelection"] as? [JSON])?.first {
                        let squared = (lod["metricType"] as? String ?? "").contains("SQ")
                        let wanted = squared ? .pi * pow(sphere[3] / Self.pixel, 2) : 2 * sphere[3] / Self.pixel
                        if wanted > number(lod["maxError"]) {
                            for child in children {
                                let m = numbers(child["mbs"])
                                if m.count >= 4 {
                                    let (ce, cn) = local(m)
                                    if hypot(ce, cn) > m[3] + reach { continue }
                                }
                                if let id = child["id"] as? String { next.append(id) }
                            }
                            continue
                        }
                    }
                    guard selected.count < Self.maxNodes, let id = node["id"] as? String,
                          let href = (node["geometryData"] as? [JSON])?.first?["href"] as? String else { continue }
                    let clean = { (h: String) in "\(root)/nodes/\(id)/" + (h.hasPrefix("./") ? String(h.dropFirst(2)) : h) }
                    var s = Selected(centre: sphere, geometry: clean(href))
                    s.positionParts = max(3, parts(position))
                    if let normal = attributes?["normal"] as? JSON { s.normalBytes = parts(normal) * bytes(normal) }
                    if let picture = (node["textureData"] as? [JSON])?.first?["href"] as? String, attributes?["uv0"] != nil {
                        s.hasUV = true
                        s.picture = clean(picture)
                    }
                    selected.append(s)
                }
                frontier = next
            }
        }
        guard !selected.isEmpty else { throw ModelError(text: "this model has nothing at that place") }

        return try await withThrowingTaskGroup(of: ModelPiece?.self) { group in
            var iterator = selected.makeIterator()
            func add() {
                guard let s = iterator.next() else { return }
                group.addTask {
                    do {
                        guard let url = URL(string: s.geometry) else { return nil }
                        let data = try await ModelLoader.fetch(url)
                        let (east, north) = local(s.centre)
                        guard var piece = Self.build([UInt8](data), s, east: east, north: north, geographic: geographic,
                                                     metresEast: metresEast, metresNorth: metresNorth) else { return nil }
                        if let address = s.picture, let url = URL(string: address) { piece.picture = try? await ModelLoader.fetch(url) }
                        return piece
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return nil
                    }
                }
            }
            for _ in 0..<6 { add() }
            var pieces: [ModelPiece] = []
            while let piece = try await group.next() {
                if let piece { pieces.append(piece) }
                add()
            }
            if pieces.isEmpty { throw ModelError(text: "no part of this model could be read") }
            return pieces
        }
    }

    /// a node: a header, then positions (3 x float32), normals, texture coordinates; x east, y north, z up from the centre of the node
    private static func build(_ b: [UInt8], _ s: Selected, east: Double, north: Double, geographic: Bool, metresEast: Double, metresNorth: Double) -> ModelPiece? {
        var count = s.vertexCount
        if count == 0 && b.count >= 4 { count = Int(ModelLoader.uint32(b, 0)) }
        let stride = s.positionParts * 4
        guard count > 0, count < 4_000_000, b.count >= s.header + count * stride else { return nil }
        func f(_ o: Int) -> Double { Double(Float(bitPattern: ModelLoader.uint32(b, o))) }
        var degrees = false // some geographic layers store the offsets in degrees
        if geographic {
            var largest = 0.0
            for v in 0..<count { largest = max(largest, abs(f(s.header + v * stride)), abs(f(s.header + v * stride + 4))) }
            degrees = largest < 0.1
        }
        let height = s.centre.count > 2 ? s.centre[2] : 0
        var piece = ModelPiece()
        piece.positions.reserveCapacity(count * 3)
        for v in 0..<count {
            let o = s.header + v * stride
            var x = f(o), y = f(o + 4)
            let z = f(o + 8)
            if degrees {
                x *= metresEast
                y *= metresNorth
            }
            piece.positions.append(Float(east + x))
            piece.positions.append(Float(height + z))
            piece.positions.append(Float(-(north + y)))
        }
        piece.indices = (0..<UInt32(count - count % 3)).map { $0 }
        if s.hasUV {
            let start = s.header + count * stride + count * s.normalBytes
            if b.count >= start + count * 8 {
                piece.uv.reserveCapacity(count * 2)
                for v in 0..<count {
                    piece.uv.append(Float(f(start + v * 8)))
                    piece.uv.append(Float(1 - f(start + v * 8 + 4)))
                }
            }
        }
        return piece
    }
}
