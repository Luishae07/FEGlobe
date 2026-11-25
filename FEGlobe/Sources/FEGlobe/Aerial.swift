// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreGraphics
import ImageIO
import Metal

/// An open source of aerial photos (Resources/aerial.json, written by tools/orthocheck from the sources that answered).
struct AerialSource: Decodable, Sendable {
    let id: String
    let credit: String
    /// has {bbox} (Web Mercator metres: west,south,east,north) or {z} {x} {y}
    let template: String
    /// west, south, east, north in degrees
    let box: [Double]
    let maxZoom: Int

    func covers(_ key: TileKey) -> Bool {
        let longitude = Geodesy.tileLongitude(column: Double(key.x) + 0.5, zoom: key.z)
        let latitude = Geodesy.tileLatitude(row: Double(key.y) + 0.5, zoom: key.z)
        return box.count == 4 && longitude >= box[0] && longitude <= box[2] && latitude >= box[1] && latitude <= box[3]
    }

    func address(_ key: TileKey) -> URL? {
        let world = 20_037_508.342789244
        let size = 2 * world / Double(1 << key.z)
        let west = -world + Double(key.x) * size, north = world - Double(key.y) * size
        let bbox = String(format: "%.4f,%.4f,%.4f,%.4f", west, north - size, west + size, north)
        return URL(string: template.replacingOccurrences(of: "{bbox}", with: bbox)
            .replacingOccurrences(of: "{z}", with: String(key.z))
            .replacingOccurrences(of: "{x}", with: String(key.x))
            .replacingOccurrences(of: "{y}", with: String(key.y)))
    }
}

/// The publishers of the aerial photos, to be named where the globe is shown.
public enum GlobeCredits {
    public static var aerialPhotos: [String] { Aerial.sources.map(\.credit) }
}

enum Aerial {
    /// the first level at which aerial photos are asked for
    static let firstZoom = 13

    static let sources: [AerialSource] = {
        guard let url = Bundle.module.url(forResource: "aerial", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AerialSource].self, from: data)) ?? []
    }()

    static func covering(_ key: TileKey) -> [AerialSource] {
        key.z < firstZoom ? [] : sources.filter { $0.covers(key) }
    }

    /// the finest level of the photos at a tile's place (nil where there are none)
    static func finest(_ key: TileKey) -> Int? {
        covering(key).map(\.maxZoom).max()
    }

    /// The photo of a tile with transparency where there is none. Boxes of neighbouring countries overlap, so the sources are laid on top of each other
    /// until the picture is full.
    static func picture(_ key: TileKey, device: MTLDevice) async -> MTLTexture? {
        let side = 256
        var result = [UInt8](repeating: 0, count: side * side * 4)
        var answered = false
        for source in covering(key).prefix(3) {
            guard key.z <= source.maxZoom, let url = source.address(key) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("FEGlobe", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                  let pixels = Pixels.decode(data), pixels.width == side, pixels.height == side else { continue }
            answered = true
            var empty = 0
            for i in stride(from: 0, to: result.count, by: 4) where result[i + 3] < 255 {
                let r = pixels.bytes[i], g = pixels.bytes[i + 1], b = pixels.bytes[i + 2], a = pixels.bytes[i + 3]
                // services that cannot be transparent fill the outside with pure white or pure black
                let nothing = a < 255 || (r >= 254 && g >= 254 && b >= 254) || (r <= 1 && g <= 1 && b <= 1)
                if nothing {
                    empty += 1
                } else {
                    result[i] = r
                    result[i + 1] = g
                    result[i + 2] = b
                    result[i + 3] = 255
                }
            }
            if empty < side * side / 200 { break }
        }
        // an answer with nothing in it is kept too (so that it is not asked again)
        return answered ? Pixels(width: side, height: side, bytes: result).texture(device) : nil
    }
}
