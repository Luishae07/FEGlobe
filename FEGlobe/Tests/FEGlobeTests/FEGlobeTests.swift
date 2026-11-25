// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import simd
@testable import FEGlobe

final class FEGlobeTests: XCTestCase {
    func testPointsOnTheSphere() {
        let north = GlobeCamera.point(latitude: 90, longitude: 0)
        XCTAssertEqual(north.y, GlobeCamera.radius, accuracy: 0.001)
        let east = GlobeCamera.point(latitude: 0, longitude: 90)
        XCTAssertEqual(east.x, GlobeCamera.radius, accuracy: 0.001)
    }

    func testLookingStraightDown() {
        let c = GlobeCamera(latitude: 52.5, longitude: 13.4, distance: 1000)
        let f = c.frame()
        XCTAssertEqual(simd_length(f.eye), GlobeCamera.radius + 1000, accuracy: 0.001)
        XCTAssertEqual(simd_dot(f.forward, simd_normalize(f.eye)), -1, accuracy: 1e-9)
        // north is up on the screen
        let north = Geodesy.basis(latitude: 52.5, longitude: 13.4).north
        XCTAssertEqual(simd_dot(f.up, north), 1, accuracy: 1e-9)
    }

    func testEastIsRight() {
        let f = GlobeCamera(latitude: 0, longitude: 0, distance: 1000).frame()
        XCTAssertEqual(f.right.x, 1, accuracy: 1e-9)
    }

    func testCameraStaysInRange() {
        var c = GlobeCamera(latitude: 100, longitude: 190, distance: 1, heading: -90, tilt: 120)
        c.clamp()
        XCTAssertEqual(c.latitude, 85)
        XCTAssertEqual(c.longitude, -170, accuracy: 1e-9)
        XCTAssertEqual(c.distance, GlobeCamera.minDistance)
        XCTAssertEqual(c.heading, 270, accuracy: 1e-9)
        XCTAssertEqual(c.tilt, 75)
    }

    func testTiles() {
        let (key, u, v) = Geodesy.tile(latitude: 0, longitude: 0, zoom: 1)
        XCTAssertEqual(key, TileKey(z: 1, x: 1, y: 1))
        XCTAssertEqual(u, 0, accuracy: 1e-9)
        XCTAssertEqual(v, 0, accuracy: 1e-9)
        let (parent, part) = TileKey(z: 3, x: 5, y: 2).clamped(to: 1)
        XCTAssertEqual(parent, TileKey(z: 1, x: 1, y: 0))
        XCTAssertEqual(part, SIMD4<Float>(0.25, 0.5, 0.25, 0.25))
    }

    func testUTM() {
        // zone 33 north: the central meridian is 15 degrees east
        let p = Geodesy.utm(x: 500_000, y: 5_800_000, zone: 33, south: false)
        XCTAssertEqual(p.longitude, 15, accuracy: 1e-9)
        XCTAssertEqual(p.latitude, 52.35, accuracy: 0.05)
    }

    func testBrokenModelsAreRefused() {
        XCTAssertThrowsError(try ModelLoader.glb(Data()))
        XCTAssertThrowsError(try ModelLoader.glb(Data(repeating: 7, count: 100)))
    }

    func testPlainDataIsNotUnpacked() {
        let data = Data("{\"a\":1}".utf8)
        XCTAssertEqual(ModelLoader.gunzipIfNeeded(data), data)
    }
}
