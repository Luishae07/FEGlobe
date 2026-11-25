// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import simd

/// Where the globe is looked at: the place in the middle of the picture, how far the eye is from it (metres), the heading (degrees clockwise from north)
/// and the tilt (degrees, 0 = straight down).
public struct GlobeCamera: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var distance: Double
    public var heading: Double
    public var tilt: Double

    public init(latitude: Double = 30, longitude: Double = 10, distance: Double = 18_000_000, heading: Double = 0, tilt: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.distance = distance
        self.heading = heading
        self.tilt = tilt
    }

    static let radius = 6_371_008.8
    static let fieldOfView = 45.0 * Double.pi / 180
    static let minDistance = 150.0
    static let maxDistance = 25_000_000.0

    mutating func clamp() {
        latitude = min(85, max(-85, latitude))
        longitude = (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        distance = min(Self.maxDistance, max(Self.minDistance, distance))
        tilt = min(75, max(0, tilt))
        heading = (heading + 360).truncatingRemainder(dividingBy: 360)
    }

    /// a point of the sphere: y points to the north pole, z to longitude 0, x to longitude 90 east
    static func point(latitude: Double, longitude: Double) -> SIMD3<Double> {
        let phi = latitude * .pi / 180, lambda = longitude * .pi / 180
        return SIMD3(cos(phi) * sin(lambda), sin(phi), cos(phi) * cos(lambda)) * radius
    }

    /// the eye and the three directions of the picture
    /// - Parameter ground: the height of the ground in the middle of the picture (metres): the distance is measured from there
    func frame(ground: Double = 0) -> (eye: SIMD3<Double>, forward: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>) {
        let h = heading * .pi / 180, t = tilt * .pi / 180
        let (east, out, north) = Geodesy.basis(latitude: latitude, longitude: longitude)
        let target = out * (Self.radius + ground)
        let ahead = north * cos(h) + east * sin(h)
        let eye = target + out * (distance * cos(t)) - ahead * (distance * sin(t))
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, ahead * cos(t) + out * sin(t)))
        return (eye, forward, right, simd_cross(right, forward))
    }
}
