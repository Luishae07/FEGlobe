// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import MetalKit
import UIKit

/// The globe as a SwiftUI view. Change the camera from outside and the globe flies there; the fingers change it from inside:
/// one finger moves, two fingers pinch to zoom, turn to rotate, and move up or down together to tilt.
public struct FEGlobeView: UIViewRepresentable {
    @Binding var camera: GlobeCamera
    private let imagery: GlobeImagery
    private let options: GlobeOptions
    private let models: [GlobeModel]
    private let status: Binding<GlobeStatus>?

    /// - Parameters:
    ///   - models: the 3D models that cover the place looked at, the best first; they are loaded when the eye is near the ground
    ///   - status: what is being loaded, and whether the phone is offline
    public init(camera: Binding<GlobeCamera>, imagery: GlobeImagery = .sentinel2, options: GlobeOptions = GlobeOptions(),
                models: [GlobeModel] = [], status: Binding<GlobeStatus>? = nil) {
        _camera = camera
        self.imagery = imagery
        self.options = options
        self.models = models
        self.status = status
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColor(red: 0.015, green: 0.02, blue: 0.045, alpha: 1)
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.preferredFramesPerSecond = 60
        let c = context.coordinator
        c.renderer = Renderer(view: view, imagery: imagery)
        view.delegate = c.renderer
        c.renderer?.set(camera)
        c.reported = c.renderer?.camera ?? camera
        let binding = $camera
        c.renderer?.onChange = { [weak c] new in
            c?.reported = new
            DispatchQueue.main.async { binding.wrappedValue = new }
        }
        let report = status
        c.renderer?.onStatus = { new in
            DispatchQueue.main.async { report?.wrappedValue = new }
        }
        c.renderer?.options = options
        c.renderer?.setModels(models)
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Globe"
        view.accessibilityTraits = .allowsDirectInteraction
        let move = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.move(_:)))
        move.maximumNumberOfTouches = 1
        let tilt = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.tilt(_:)))
        tilt.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let turn = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.turn(_:)))
        let twice = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        twice.numberOfTapsRequired = 2
        for gesture in [move, tilt, pinch, turn, twice] as [UIGestureRecognizer] {
            gesture.delegate = c
            view.addGestureRecognizer(gesture)
        }
        return view
    }

    public func updateUIView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        c.renderer?.options = options
        c.renderer?.setModels(models)
        // a camera that did not come from the globe itself: fly there
        if camera != c.reported && camera != c.asked {
            c.asked = camera
            c.renderer?.fly(to: camera)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: Renderer?
        var reported = GlobeCamera()
        var asked: GlobeCamera?

        private func change(_ edit: (inout GlobeCamera) -> Void) {
            guard let renderer else { return }
            var c = renderer.camera
            edit(&c)
            renderer.set(c)
        }

        @objc func move(_ g: UIPanGestureRecognizer) {
            guard let view = g.view, view.bounds.height > 0 else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            change { c in
                let metres = c.distance * 2 * tan(GlobeCamera.fieldOfView / 2) / Double(view.bounds.height)
                let sideways = -Double(t.x) * metres, ahead = Double(t.y) * metres
                let h = c.heading * .pi / 180
                let north = ahead * cos(h) - sideways * sin(h)
                let east = ahead * sin(h) + sideways * cos(h)
                c.latitude += north / GlobeCamera.radius * 180 / .pi
                c.longitude += east / (GlobeCamera.radius * max(0.2, cos(c.latitude * .pi / 180))) * 180 / .pi
            }
        }

        @objc func tilt(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            if abs(t.y) > abs(t.x) { change { $0.tilt -= Double(t.y) * 0.35 } }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            let scale = Double(g.scale)
            g.scale = 1
            if scale > 0 { change { $0.distance /= scale } }
        }

        @objc func turn(_ g: UIRotationGestureRecognizer) {
            let angle = Double(g.rotation) * 180 / .pi
            g.rotation = 0
            change { $0.heading -= angle }
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let renderer else { return }
            var c = renderer.camera
            c.distance /= 2.5
            renderer.fly(to: c, duration: 0.6)
        }

        public func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }
    }
}
