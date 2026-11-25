// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Compression

/// A 3D model that the globe can show around the place that is looked at.
public struct GlobeModel: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// an Esri scene layer (I3S integrated mesh): the address of its SceneServer
        case sceneLayer(URL)
        /// a service that answers `?lon=&lat=&radius=&format=glb` with a model in local coordinates (x east, y up, z south)
        case modelService(URL)
    }
    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// One piece of a model: x east, y up, z south (metres from the place that was asked for), texture coordinates, triangles, the picture file.
struct ModelPiece: Sendable {
    var positions: [Float] = []
    var uv: [Float] = []
    var indices: [UInt32] = []
    var picture: Data?
}

struct ModelError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

enum ModelLoader {
    static func load(_ model: GlobeModel, latitude: Double, longitude: Double, radius: Double) async throws -> [ModelPiece] {
        switch model.kind {
        case .sceneLayer(let url):
            return try await SceneLayerReader(base: url.absoluteString, latitude: latitude, longitude: longitude, radius: radius).read()
        case .modelService(let url):
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.queryItems = [URLQueryItem(name: "lon", value: String(format: "%.6f", longitude)), URLQueryItem(name: "lat", value: String(format: "%.6f", latitude)),
                             URLQueryItem(name: "radius", value: String(Int(min(300, radius)))), URLQueryItem(name: "format", value: "glb")]
            guard let full = c?.url else { throw ModelError(text: "bad address") }
            return try glb(await fetch(full))
        }
    }

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.setValue("FEGlobe", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ModelError(text: "the server answered \(status)") }
        return gunzipIfNeeded(data)
    }

    /// Some scene layers store gzip files; the compression of the transfer is undone by the system already.
    static func gunzipIfNeeded(_ data: Data) -> Data {
        let b = [UInt8](data.prefix(10))
        guard b.count == 10, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return data }
        let bytes = [UInt8](data)
        let flags = bytes[3]
        var at = 10
        if flags & 4 != 0, at + 2 <= bytes.count { at += 2 + Int(bytes[at]) + Int(bytes[at + 1]) << 8 }
        if flags & 8 != 0 { while at < bytes.count && bytes[at] != 0 { at += 1 }; at += 1 }
        if flags & 16 != 0 { while at < bytes.count && bytes[at] != 0 { at += 1 }; at += 1 }
        if flags & 2 != 0 { at += 2 }
        guard at < bytes.count - 8 else { return data }
        // Apple's "zlib" is a plain deflate stream
        return (try? (Data(bytes[at..<(bytes.count - 8)]) as NSData).decompressed(using: .zlib) as Data) ?? data
    }

    // MARK: glTF binary

    static func glb(_ data: Data) throws -> [ModelPiece] {
        let bytes = [UInt8](data)
        guard bytes.count > 20, uint32(bytes, 0) == 0x46546C67 else { throw ModelError(text: "not a glTF model") }
        let jsonLength = Int(uint32(bytes, 12))
        guard 20 + jsonLength + 8 <= bytes.count,
              let j = try JSONSerialization.jsonObject(with: Data(bytes[20..<(20 + jsonLength)])) as? [String: Any] else { throw ModelError(text: "broken model") }
        let bin = 20 + jsonLength + 8
        let accessors = j["accessors"] as? [[String: Any]] ?? [], views = j["bufferViews"] as? [[String: Any]] ?? []
        let materials = j["materials"] as? [[String: Any]] ?? [], textures = j["textures"] as? [[String: Any]] ?? [], images = j["images"] as? [[String: Any]] ?? []
        func place(_ a: Int, size: Int) throws -> (offset: Int, count: Int, stride: Int, type: Int) {
            guard a < accessors.count, let v = accessors[a]["bufferView"] as? Int, v < views.count else { throw ModelError(text: "broken model") }
            let count = accessors[a]["count"] as? Int ?? 0
            let offset = bin + (views[v]["byteOffset"] as? Int ?? 0) + (accessors[a]["byteOffset"] as? Int ?? 0)
            let stride = views[v]["byteStride"] as? Int ?? size
            guard count >= 0, offset >= 0, count == 0 || offset + (count - 1) * stride + size <= bytes.count else { throw ModelError(text: "model cut short") }
            return (offset, count, stride, accessors[a]["componentType"] as? Int ?? 5126)
        }
        func floats(_ a: Int, _ n: Int) throws -> [Float] {
            let p = try place(a, size: n * 4)
            var out = [Float](repeating: 0, count: p.count * n)
            for i in 0..<p.count {
                for c in 0..<n { out[i * n + c] = Float(bitPattern: uint32(bytes, p.offset + i * p.stride + c * 4)) }
            }
            return out
        }
        var pieces: [ModelPiece] = []
        for mesh in j["meshes"] as? [[String: Any]] ?? [] {
            for primitive in mesh["primitives"] as? [[String: Any]] ?? [] {
                guard let attributes = primitive["attributes"] as? [String: Int], let position = attributes["POSITION"] else { continue }
                var piece = ModelPiece()
                piece.positions = try floats(position, 3)
                if let t = attributes["TEXCOORD_0"] { piece.uv = try floats(t, 2) }
                if let index = primitive["indices"] as? Int, index < accessors.count {
                    let type = accessors[index]["componentType"] as? Int ?? 5125
                    let width = type == 5125 ? 4 : type == 5123 ? 2 : 1
                    let p = try place(index, size: width)
                    piece.indices = (0..<p.count).map { i in
                        let o = p.offset + i * p.stride
                        if width == 4 { return uint32(bytes, o) }
                        if width == 2 { return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 }
                        return UInt32(bytes[o])
                    }
                } else {
                    piece.indices = (0..<UInt32(piece.positions.count / 3)).map { $0 }
                }
                if let m = primitive["material"] as? Int, m < materials.count,
                   let pbr = materials[m]["pbrMetallicRoughness"] as? [String: Any], let base = pbr["baseColorTexture"] as? [String: Any],
                   let t = base["index"] as? Int, t < textures.count, let source = textures[t]["source"] as? Int, source < images.count,
                   let v = images[source]["bufferView"] as? Int, v < views.count {
                    let o = bin + (views[v]["byteOffset"] as? Int ?? 0), l = views[v]["byteLength"] as? Int ?? 0
                    if o >= 0, o + l <= bytes.count { piece.picture = Data(bytes[o..<(o + l)]) }
                }
                pieces.append(piece)
            }
        }
        if pieces.isEmpty { throw ModelError(text: "the model is empty here") }
        return pieces
    }

    static func uint32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
