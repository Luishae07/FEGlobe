// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import simd

enum Geodesy {
    static func tileLatitude(row: Double, zoom: Int) -> Double {
        atan(sinh(.pi * (1 - 2 * row / Double(1 << zoom)))) * 180 / .pi
    }

    static func tileLongitude(column: Double, zoom: Int) -> Double {
        column / Double(1 << zoom) * 360 - 180
    }

    /// the tile that holds a place, and where in it (0...1)
    static func tile(latitude: Double, longitude: Double, zoom: Int) -> (TileKey, Double, Double) {
        let n = Double(1 << zoom)
        let phi = min(85.05, max(-85.05, latitude)) * .pi / 180
        let x = (longitude + 180) / 360 * n
        let y = (1 - log(tan(phi) + 1 / cos(phi)) / .pi) / 2 * n
        let tx = min(Int(n) - 1, max(0, Int(x))), ty = min(Int(n) - 1, max(0, Int(y)))
        return (TileKey(z: zoom, x: tx, y: ty), x - Double(tx), y - Double(ty))
    }

    /// east, up and north at a place, on the sphere
    static func basis(latitude: Double, longitude: Double) -> (east: SIMD3<Double>, up: SIMD3<Double>, north: SIMD3<Double>) {
        let phi = latitude * .pi / 180, lambda = longitude * .pi / 180
        return (SIMD3(cos(lambda), 0, -sin(lambda)),
                SIMD3(cos(phi) * sin(lambda), sin(phi), cos(phi) * cos(lambda)),
                SIMD3(-sin(phi) * sin(lambda), cos(phi), -sin(phi) * cos(lambda)))
    }

    /// where the sun stands overhead at a time, as a direction
    static func sunDirection(_ date: Date) -> SIMD3<Double> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hours = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        let latitude = 23.44 * sin(2 * .pi * (284 + day) / 365)
        let longitude = -15 * (hours - 12)
        return basis(latitude: latitude, longitude: longitude).up
    }

    /// the inverse transverse Mercator (Krueger series) on the WGS84 ellipsoid
    static func utm(x: Double, y: Double, zone: Int, south: Bool) -> (longitude: Double, latitude: Double) {
        let a = 6378137.0, f = 1 / 298.257223563
        let n = f / (2 - f)
        let A = a / (1 + n) * (1 + n * n / 4 + n * n * n * n / 64)
        let b = [n / 2 - 2 * n * n / 3 + 37 * n * n * n / 96, n * n / 48 + n * n * n / 15, 17 * n * n * n / 480]
        let d = [2 * n - 2 * n * n / 3 - 2 * n * n * n, 7 * n * n / 3 - 8 * n * n * n / 5, 56 * n * n * n / 15]
        let northing = south ? y - 10_000_000 : y
        let xi = northing / (0.9996 * A), eta = (x - 500_000) / (0.9996 * A)
        var xi2 = xi, eta2 = eta
        for j in 0..<3 {
            let k = Double(2 * (j + 1))
            xi2 -= b[j] * sin(k * xi) * cosh(k * eta)
            eta2 -= b[j] * cos(k * xi) * sinh(k * eta)
        }
        let chi = asin(sin(xi2) / cosh(eta2))
        var lat = chi
        for j in 0..<3 { lat += d[j] * sin(Double(2 * (j + 1)) * chi) }
        let lon = atan2(sinh(eta2), cos(xi2)) * 180 / .pi + Double(zone * 6 - 183)
        return ((lon + 540).truncatingRemainder(dividingBy: 360) - 180, lat * 180 / .pi)
    }

    /// (zone, south) when the coordinate system is a UTM one
    static func utmZone(_ wkid: Int) -> (Int, Bool)? {
        switch wkid {
        case 25828...25838: return (wkid - 25800, false)
        case 32601...32660: return (wkid - 32600, false)
        case 32701...32760: return (wkid - 32700, true)
        case 26901...26923: return (wkid - 26900, false)
        case 28348...28358: return (wkid - 28300, true)
        case 7846...7859: return (wkid - 7800, true)
        default: return nil
        }
    }
}
