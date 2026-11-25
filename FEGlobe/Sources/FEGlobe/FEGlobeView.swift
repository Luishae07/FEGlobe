// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import MetalKit
import UIKit

/// The globe as a SwiftUI view. Change the camera from outside and the globe flies there. The fingers work as in the well-known globes: one finger moves
/// the map (and it glides on), two fingers zoom and turn around the point between them, two fingers side by side moved up or down tilt the view,
/// a double tap zooms in, a tap with two fingers zooms out.
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
        tilt.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let turn = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.turn(_:)))
        let twice = UITapGestureRecognizer(target: c, action: #selector(Coordinator.zoomIn(_:)))
        twice.numberOfTapsRequired = 2
        let two = UITapGestureRecognizer(target: c, action: #selector(Coordinator.zoomOut(_:)))
        two.numberOfTouchesRequired = 2
        c.tiltGesture = tilt
        // a tilt is decided first: only when it is not one do the fingers zoom and turn
        pinch.require(toFail: tilt)
        turn.require(toFail: tilt)
        for gesture in [move, tilt, pinch, turn, twice, two] as [UIGestureRecognizer] {
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
        weak var tiltGesture: UIPanGestureRecognizer?

        @objc func move(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            switch g.state {
            case .changed, .began:
                let t = g.translation(in: view), now = g.location(in: view)
                g.setTranslation(.zero, in: view)
                renderer?.move { camera, ground in
                    camera.drag(from: CGPoint(x: now.x - t.x, y: now.y - t.y), to: now, in: view.bounds.size, ground: ground)
                }
            case .ended:
                renderer?.swipe(velocity: g.velocity(in: view), size: view.bounds.size)
            default:
                break
            }
        }

        @objc func tilt(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            renderer?.move { camera, _ in camera.tilt -= Double(t.y) * 0.3 }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let view = g.view, g.numberOfTouches >= 2 else { return }
            let scale = Double(g.scale), focus = g.location(in: view)
            g.scale = 1
            guard scale > 0 else { return }
            renderer?.move { camera, ground in
                camera.keeping(focus, in: view.bounds.size, ground: ground) { $0.distance /= scale }
            }
        }

        @objc func turn(_ g: UIRotationGestureRecognizer) {
            guard let view = g.view, g.numberOfTouches >= 2 else { return }
            let angle = Double(g.rotation) * 180 / .pi, focus = g.location(in: view)
            g.rotation = 0
            renderer?.move { camera, ground in
                camera.keeping(focus, in: view.bounds.size, ground: ground) { $0.heading -= angle }
            }
        }

        private func zoom(_ factor: Double, _ g: UIGestureRecognizer) {
            guard let renderer, let view = g.view else { return }
            var c = renderer.camera
            c.keeping(g.location(in: view), in: view.bounds.size, ground: 0) { $0.distance /= factor }
            renderer.fly(to: c, duration: 0.45)
        }

        @objc func zoomIn(_ g: UITapGestureRecognizer) { zoom(2.5, g) }
        @objc func zoomOut(_ g: UITapGestureRecognizer) { zoom(0.4, g) }

        public func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            renderer?.stopMotion()
            return true
        }

        /// a tilt: two fingers side by side that move up or down
        public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === tiltGesture, let pan = g as? UIPanGestureRecognizer, let view = g.view else { return true }
            guard pan.numberOfTouches == 2 else { return false }
            let a = pan.location(ofTouch: 0, in: view), b = pan.location(ofTouch: 1, in: view)
            let v = pan.velocity(in: view)
            return abs(a.x - b.x) > abs(a.y - b.y) && abs(v.y) > abs(v.x) * 1.5
        }

        public func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            (a is UIPinchGestureRecognizer && b is UIRotationGestureRecognizer) || (a is UIRotationGestureRecognizer && b is UIPinchGestureRecognizer)
        }
    }
}
