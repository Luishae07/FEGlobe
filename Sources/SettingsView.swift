// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct SettingsView: View {
    @Binding var engine: Engine
    let photoCount: Int
    let esriCount: Int
    @Environment(\.dismiss) private var dismiss
    @AppStorage("terrain") private var terrain = true
    @AppStorage("sunlight") private var sunlight = true
    @AppStorage("placeNames") private var placeNames = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Globe", selection: $engine) {
                        ForEach(Engine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Globe")
                } footer: {
                    Text(engine == .feglobe ? "Our own open source globe with the 3D models of the Atlas." : "Apple's globe and Apple's own 3D cities.")
                }
                if engine == .feglobe {
                    Section("FEGlobe") {
                        Toggle("Terrain", isOn: $terrain)
                        Toggle("Sunlight and city lights", isOn: $sunlight)
                        Toggle("Place names", isOn: $placeNames)
                    }
                }
                Section("3D models in the Atlas") {
                    LabeledContent("Photo meshes", value: "\(photoCount)")
                    LabeledContent("Esri scene layers", value: "\(esriCount)")
                }
                Section("Credits and licences") {
                    Text("FEGlobe engine: AGPL-3.0-or-later, with an App Store exception. App: MPL-2.0.")
                    Text("Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016 & 2017), CC BY 4.0")
                    Link("Licence CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                    Text("Night lights and place names: NASA GIBS. Terrain: Terrain Tiles on AWS (Mapzen, SRTM, NASA and others).")
                    Link("Mesh Atlas: owners of the models", destination: URL(string: "https://mesh.flowsearch.org")!)
                }
                .font(.footnote)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
