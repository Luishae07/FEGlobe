// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreGraphics
import simd

/// What the fingers do. The rule of every good globe: the place under the fingers stays under the fingers.
extension GlobeCamera {
    /// the place on the ground that is seen at a point of the view, or nil for the sky
    func place(at point: CGPoint, in size: CGSize, ground: Double) -> (latitude: Double, longitude: Double)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let (eye, forward, right, up) = frame(ground: ground)
        let tanY = tan(Self.fieldOfView / 2), tanX = tanY * Double(size.width / size.height)
        let x = (2 * Double(point.x / size.width) - 1) * tanX
        let y = (1 - 2 * Double(point.y / size.height)) * tanY
        let direction = simd_normalize(forward + right * x + up * y)
        let radius = Self.radius + ground
        let b = simd_dot(eye, direction), c = simd_length_squared(eye) - radius * radius
        let d = b * b - c
        guard d >= 0 else { return nil }
        let t = -b - d.squareRoot()
        guard t > 0 else { return nil }
        let hit = eye + direction * t
        return (asin(max(-1, min(1, hit.y / simd_length(hit)))) * 180 / .pi, atan2(hit.x, hit.z) * 180 / .pi)
    }

    /// moves the map so that what was under `from` is under `to`
    mutating func drag(from: CGPoint, to: CGPoint, in size: CGSize, ground: Double) {
        if let a = place(at: from, in: size, ground: ground), let b = place(at: to, in: size, ground: ground) {
            let north = a.latitude - b.latitude
            let east = (a.longitude - b.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            let moved = (north * north + pow(east * cos(latitude * .pi / 180), 2)).squareRoot() * .pi / 180 * Self.radius
            // near the horizon a small movement of the finger is a huge way on the ground: not followed there
            if moved < distance * 0.6 {
                latitude += north
                longitude += east
                clamp()
                return
            }
        }
        let metres = distance * 2 * tan(Self.fieldOfView / 2) / Double(max(1, size.height))
        let sideways = -Double(to.x - from.x) * metres, ahead = Double(to.y - from.y) * metres
        let h = heading * .pi / 180
        latitude += (ahead * cos(h) - sideways * sin(h)) / Self.radius * 180 / .pi
        longitude += (ahead * sin(h) + sideways * cos(h)) / (Self.radius * max(0.2, cos(latitude * .pi / 180))) * 180 / .pi
        clamp()
    }

    /// changes the camera and keeps the place under `point` where it is (zooming and turning around the fingers)
    mutating func keeping(_ point: CGPoint, in size: CGSize, ground: Double, _ change: (inout GlobeCamera) -> Void) {
        let before = place(at: point, in: size, ground: ground)
        change(&self)
        clamp()
        guard distance < 8_000_000, let before, let after = place(at: point, in: size, ground: ground) else { return }
        let north = before.latitude - after.latitude
        let east = (before.longitude - after.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        let moved = (north * north + pow(east * cos(latitude * .pi / 180), 2)).squareRoot() * .pi / 180 * Self.radius
        guard moved < distance else { return }
        latitude += north
        longitude += east
        clamp()
    }
}
