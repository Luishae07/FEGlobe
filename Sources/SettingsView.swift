// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct SettingsView: View {
    @Binding var engine: Engine
    let photoMeshes: [MeshModel]
    let esri: [MeshModel]
    /// flies to a model chosen in one of the lists
    let open: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("placeNames") private var placeNames = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Map", selection: $engine) {
                        ForEach(Engine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Map")
                } footer: {
                    Text(engine == .arcgis ? "3D globe with the models of the Atlas." : "Apple's globe and Apple's own 3D cities. The Atlas models are not shown.")
                }
                if engine == .arcgis {
                    Section {
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
    /// who owns what is on the screen now
    var onScreen: [String] = []

    var body: some View {
        Form {
            if !onScreen.isEmpty {
                Section("On the screen") {
                    ForEach(onScreen, id: \.self) { Text($0).font(.footnote) }
                }
            }
            Section("Code") {
                LabeledContent("This app", value: "MPL-2.0")
                LabeledContent("Maps", value: "ArcGIS Maps SDK (Esri), Apple MapKit")
                Text("The ArcGIS Maps SDK for Swift is Esri's own software under Esri's licence; it is not open source.").font(.footnote)
                Link("Source code of the app", destination: URL(string: "https://github.com/Luishae07/FEGlobe")!)
            }
            Section("Pictures and terrain") {
                Text("Satellite: Powered by Esri. Esri, Maxar, Earthstar Geographics, and the GIS User Community. The pictures come through flowsearch.org, so Esri does not see your address.")
                Text("Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016 & 2017), CC BY 4.0")
                Text("Where Esri's picture does not come, close up: aerial photos of the government services named on the screen; German ones come through mesh.flowsearch.org, which keeps copies.")
                Text("Names: NASA GIBS. Terrain: Esri World Elevation.")
                Text("App icon: Natural Earth (public domain).")
            }
            Section("3D models") {
                Text("They belong to their owners, who are named on the screen.")
                Link("Mesh Atlas", destination: URL(string: "https://mesh.flowsearch.org")!)
            }
        }
        .navigationTitle("Licences and credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}
