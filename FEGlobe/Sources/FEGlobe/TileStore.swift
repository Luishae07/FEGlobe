// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Metal
import CoreGraphics
import ImageIO

/// A square of the Web Mercator map.
struct TileKey: Hashable {
    let z: Int
    let x: Int
    let y: Int
    var parent: TileKey { TileKey(z: z - 1, x: x / 2, y: y / 2) }

    /// this tile, or the one above it at `level`, with the part of that one which covers this tile (offset x, y and scale)
    func clamped(to level: Int) -> (TileKey, SIMD4<Float>) {
        guard z > level else { return (self, SIMD4(0, 0, 1, 1)) }
        let n = 1 << (z - level)
        let s = 1 / Float(n)
        return (TileKey(z: level, x: x / n, y: y / n), SIMD4(Float(x % n) * s, Float(y % n) * s, s, s))
    }
}

/// A layer of map pictures. The address has {z}, {x} and {y}.
public struct GlobeImagery: Sendable {
    public var urlTemplate: String
    public var maxZoom: Int
    public var attribution: String
    /// a second source for the tiles that the first one does not have, up to `fallbackMaxZoom`
    public var fallbackTemplate: String?
    public var fallbackMaxZoom: Int

    public init(urlTemplate: String, maxZoom: Int, attribution: String, fallbackTemplate: String? = nil, fallbackMaxZoom: Int = 0) {
        self.urlTemplate = urlTemplate
        self.maxZoom = maxZoom
        self.attribution = attribution
        self.fallbackTemplate = fallbackTemplate
        self.fallbackMaxZoom = fallbackMaxZoom
    }

    /// VersaTiles satellite: official aerial photos where governments publish them openly (Germany with Berlin, and many more), satellite mosaics
    /// elsewhere. No key; every source is openly licensed (https://versatiles.org/sources/). A donation funded service: heavy users should donate
    /// or host the tiles themselves.
    public static let versatiles = GlobeImagery(
        urlTemplate: "https://tiles.versatiles.org/tiles/satellite/{z}/{x}/{y}",
        maxZoom: 19,
        attribution: "Imagery: VersaTiles and its sources, versatiles.org/sources; where it has none: Sentinel-2 cloudless - https://s2maps.eu by EOX (Contains modified Copernicus Sentinel data 2016 & 2017), CC BY 4.0",
        fallbackTemplate: "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg", fallbackMaxZoom: 14)

    /// Sentinel-2 cloudless 2016 by EOX: 10 m a pixel, CC BY 4.0 (commercial use allowed with this attribution). The later years are for non-commercial use only.
    public static let sentinel2 = GlobeImagery(
        urlTemplate: "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg",
        maxZoom: 14,
        attribution: "Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016 & 2017), CC BY 4.0")
    /// NASA Black Marble: the lights of the cities at night.
    public static let nightLights = GlobeImagery(
        urlTemplate: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/VIIRS_Black_Marble/default/GoogleMapsCompatible_Level8/{z}/{y}/{x}.png",
        maxZoom: 8, attribution: "NASA Black Marble (GIBS)")
    /// NASA GIBS reference labels: names of countries, cities and places.
    public static let placeNames = GlobeImagery(
        urlTemplate: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/Reference_Labels/default/GoogleMapsCompatible_Level9/{z}/{y}/{x}.png",
        maxZoom: 9, attribution: "Labels: NASA GIBS")
}

/// Pixels of a picture as RGBA bytes.
struct Pixels {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    /// - Parameter brightnessIsAlpha: for pictures without transparency (white writing on black): the brightness becomes the opacity.
    static func decode(_ data: Data, brightnessIsAlpha: Bool = false) -> Pixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let info = image.alphaInfo
        let opaque = info == CGImageAlphaInfo.none || info == .noneSkipFirst || info == .noneSkipLast
        if brightnessIsAlpha && opaque {
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let m = max(bytes[i], max(bytes[i + 1], bytes[i + 2]))
                bytes[i] = m
                bytes[i + 1] = m
                bytes[i + 2] = m
                bytes[i + 3] = m
            }
        }
        return Pixels(width: w, height: h, bytes: bytes)
    }

    func texture(_ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return t
    }
}

/// Loads things of tiles in the background and keeps the last ones in memory.
@MainActor
final class TileCache<Value> {
    private let imagery: GlobeImagery
    private let limit: Int
    private let decode: @Sendable (Data) -> Value?
    private var values: [TileKey: (value: Value, used: Int)] = [:]
    private var loading: Set<TileKey> = []
    private var failed: [TileKey: Date] = [:]
    /// tiles that the source does not have (404): the tile above stands in for them
    private var absent: Set<TileKey> = []
    var frame = 0
    var onArrival: (() -> Void)?
    var onFailure: ((Bool) -> Void)?

    init(imagery: GlobeImagery, limit: Int, decode: @escaping @Sendable (Data) -> Value?) {
        self.imagery = imagery
        self.limit = limit
        self.decode = decode
    }

    var maxZoom: Int { imagery.maxZoom }

    /// the value of a tile if it is here, else nil (and it is asked for)
    func value(_ key: TileKey) -> Value? {
        if let entry = values[key] {
            values[key] = (entry.value, frame)
            return entry.value
        }
        load(key)
        return nil
    }

    /// the value of a tile, or of the nearest tile above it that is here, with the part of it that covers the tile
    func best(_ key: TileKey) -> (Value, SIMD4<Float>)? {
        var (wanted, part) = key.clamped(to: maxZoom)
        while wanted.z > 0 && absent.contains(wanted) { // not every place has the finest pictures
            wanted = wanted.parent
            part = key.clamped(to: wanted.z).1
        }
        if let v = value(wanted) { return (v, part) }
        var above = wanted
        while above.z > 0 {
            above = above.parent
            if let entry = values[above] {
                values[above] = (entry.value, frame)
                return (entry.value, key.clamped(to: above.z).1)
            }
        }
        load(TileKey(z: min(2, maxZoom), x: wanted.x >> max(0, wanted.z - 2), y: wanted.y >> max(0, wanted.z - 2)))
        return nil
    }

    func clear() { values.removeAll() }

    private func load(_ key: TileKey) {
        if loading.count >= 8 || loading.contains(key) || absent.contains(key) { return }
        if let when = failed[key], Date().timeIntervalSince(when) < 30 { return }
        func address(_ template: String) -> URL? {
            URL(string: template
                .replacingOccurrences(of: "{z}", with: String(key.z))
                .replacingOccurrences(of: "{x}", with: String(key.x))
                .replacingOccurrences(of: "{y}", with: String(key.y)))
        }
        guard let url = address(imagery.urlTemplate) else { return }
        let second = key.z <= imagery.fallbackMaxZoom ? imagery.fallbackTemplate.flatMap { address($0) } : nil
        loading.insert(key)
        let decode = decode
        Task {
            defer { loading.remove(key) }
            do {
                var (data, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 404, let second {
                    (data, response) = try await URLSession.shared.data(from: second)
                }
                if (response as? HTTPURLResponse)?.statusCode == 404 {
                    absent.insert(key)
                    onArrival?() // draw again: the tile above is asked for now
                    return
                }
                let received = data
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let value = await Task.detached(priority: .userInitiated, operation: { Box(decode(received)) }).value.value else {
                    failed[key] = Date()
                    return
                }
                values[key] = (value, frame)
                onFailure?(false)
                onArrival?()
                trim()
            } catch {
                failed[key] = Date()
                if (error as? URLError)?.code == .notConnectedToInternet { onFailure?(true) }
            }
        }
    }

    private func trim() {
        guard values.count > limit else { return }
        for (key, _) in values.sorted(by: { $0.value.used < $1.value.used }).prefix(values.count - limit + limit / 10) where key.z > 2 {
            values[key] = nil
        }
    }
}

/// carries a decoded value from the background task
struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// The height of the ground of a tile, in metres (Terrain Tiles on AWS: Mapzen "terrarium" pictures).
struct Elevation {
    let size: Int
    let metres: [Float]

    static let source = GlobeImagery(urlTemplate: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png", maxZoom: 13,
                                     attribution: "Terrain Tiles: Mapzen, SRTM, NASA and others")

    static func decode(_ data: Data) -> Elevation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == image.height, image.bitsPerComponent == 8, image.bitsPerPixel >= 24,
              let raw = image.dataProvider?.data, let bytes = CFDataGetBytePtr(raw) else { return nil }
        let n = image.width, step = image.bitsPerPixel / 8, row = image.bytesPerRow
        var out = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let p = y * row + x * step
                out[y * n + x] = Float(bytes[p]) * 256 + Float(bytes[p + 1]) + Float(bytes[p + 2]) / 256 - 32768
            }
        }
        return Elevation(size: n, metres: out)
    }

    /// the height at u, v (0...1) of the tile; the sea floor counts as sea level
    func sample(_ u: Double, _ v: Double) -> Double {
        let fx = min(Double(size - 1), max(0, u * Double(size - 1))), fy = min(Double(size - 1), max(0, v * Double(size - 1)))
        let x = Int(fx), y = Int(fy), x1 = min(size - 1, x + 1), y1 = min(size - 1, y + 1)
        let wx = fx - Double(x), wy = fy - Double(y)
        let top = Double(metres[y * size + x]) * (1 - wx) + Double(metres[y * size + x1]) * wx
        let bottom = Double(metres[y1 * size + x]) * (1 - wx) + Double(metres[y1 * size + x1]) * wx
        return max(0, top * (1 - wy) + bottom * wy)
    }
}
