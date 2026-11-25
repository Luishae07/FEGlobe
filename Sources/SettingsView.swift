// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct SettingsView: View {
    @Binding var engine: Engine
    let photoMeshes: [MeshModel]
    let esri: [MeshModel]
    /// flies to a model chosen in one of the lists
    let open: (Place) -> Void
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
                    modelRow("Photo meshes", photoMeshes)
                    modelRow("Esri scene layers", esri)
                }
                Section {
                    NavigationLink("Licences and credits") { LicencesView() }
                }
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

    private func modelRow(_ title: String, _ models: [MeshModel]) -> some View {
        NavigationLink {
            ModelList(title: title, models: models) { place in
                dismiss()
                open(place)
            }
        } label: {
            LabeledContent(title, value: "\(models.count)")
        }
        .disabled(models.isEmpty)
    }
}

/// All models of one kind, with a search field; a tap flies there.
struct ModelList: View {
    let title: String
    let models: [MeshModel]
    let open: (Place) -> Void
    @State private var query = ""

    private var found: [MeshModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return models }
        return models.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.owner?.localizedCaseInsensitiveContains(q) ?? false) }
    }

    var body: some View {
        List(found) { model in
            Button {
                open(model.place)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).foregroundStyle(.primary).lineLimit(2)
                    if let owner = model.owner { Text(owner).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
        .overlay {
            if found.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or owner")
        .navigationTitle(title)
    }
}

struct LicencesView: View {
    var body: some View {
        Form {
            Section("Code") {
                LabeledContent("FEGlobe engine", value: "AGPL-3.0-or-later")
                LabeledContent("App", value: "MPL-2.0")
                Text("The engine has an additional permission for distribution through the App Store.").font(.footnote)
                Link("Source code", destination: URL(string: "https://github.com/Luishae07/FEGlobe")!)
            }
            Section("Satellite imagery") {
                Text("VersaTiles satellite: official aerial photos published openly by governments, and open satellite mosaics (Copernicus Sentinel-2, NASA Blue Marble). Every source has its own credit and open licence:")
                Link("All sources and licences", destination: URL(string: "https://versatiles.org/sources/")!)
                Text("Where VersaTiles has no picture: Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016 & 2017), CC BY 4.0")
            }
            Section("Other data") {
                Text("Night lights and place names: NASA GIBS.")
                Text("Terrain: Terrain Tiles on AWS (Mapzen, SRTM, NASA and others).")
                Text("App icon: Natural Earth (public domain).")
                Text("3D models belong to their owners, who are named on the globe.")
                Link("Mesh Atlas", destination: URL(string: "https://mesh.flowsearch.org")!)
            }
        }
        .navigationTitle("Licences and credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}
