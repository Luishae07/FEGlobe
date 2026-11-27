// SPDX-License-Identifier: MPL-2.0
import ArcGIS
import CryptoKit
import Foundation

/// Esri World Imagery through the Flowsearch server, which holds the account's key. Every request carries the time and its
/// HMAC-SHA256, keyed with a number written into Secrets.swift when the app is built (not part of the source code).
/// Only where Esri's picture does not come, the official aerial photo of the place is asked for instead.
enum Satellite {
    private static let edge = 20037508.342789244

    private static func picture(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let answer = response as? HTTPURLResponse, answer.statusCode == 200, answer.mimeType?.hasPrefix("image/") == true else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func esri(level: Int, row: Int, column: Int) async throws -> Data {
        if atlasTileNumber.isEmpty { throw URLError(.userAuthenticationRequired) }
        let time = String(Int(Date().timeIntervalSince1970))
        let code = HMAC<SHA256>.authenticationCode(for: Data(time.utf8), using: SymmetricKey(data: Data(atlasTileNumber.utf8)))
        var request = URLRequest(url: URL(string: "https://flowsearch.org/api/app-map?z=\(level)&y=\(row)&x=\(column)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue(time, forHTTPHeaderField: "X-Atlas-Time")
        request.setValue(code.map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "X-Atlas-Sign")
        return try await picture(request)
    }

    /// the official aerial photo of the same square, from the first source that covers it and answers (close levels only)
    private static func official(_ sources: [AerialSource], level: Int, row: Int, column: Int) async throws -> Data {
        let count = Double(1 << level)
        let longitude = (Double(column) + 0.5) / count * 360 - 180
        let latitude = atan(sinh(Double.pi * (1 - 2 * (Double(row) + 0.5) / count))) * 180 / Double.pi
        if level >= 11 {
            for source in sources where source.covers(latitude: latitude, longitude: longitude) {
                guard let url = source.tileURL(level: level, row: row, column: column) else { continue }
                var request = URLRequest(url: url)
                request.timeoutInterval = 25
                if let data = try? await picture(request) { return data }
            }
        }
        throw URLError(.resourceUnavailable) // the Sentinel-2 picture below is seen
    }

    static func layer(_ sources: [AerialSource]) -> Layer {
        let levels = (0...18).map { LevelOfDetail(level: $0, resolution: 156543.03392804097 / Double(1 << $0), scale: 591657527.591555 / Double(1 << $0)) }
        let info = TileInfo(dpi: 96, format: .mixed, levelsOfDetail: levels, origin: Point(x: -edge, y: edge, spatialReference: .webMercator),
                            spatialReference: .webMercator, tileHeight: 256, tileWidth: 256)
        let layer = CustomTiledLayer(tileInfo: info,
                                     fullExtent: Envelope(xMin: -edge, yMin: -edge, xMax: edge, yMax: edge, spatialReference: .webMercator)) { key in
            do {
                return try await esri(level: key.level, row: key.row, column: key.column)
            } catch {
                try Task.checkCancellation()
                return try await official(sources, level: key.level, row: key.row, column: key.column)
            }
        }
        layer.attribution = "Powered by Esri. Esri, Maxar, Earthstar Geographics, and the GIS User Community"
        return layer
    }
}
