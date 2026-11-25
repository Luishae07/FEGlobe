import SwiftUI
import MapKit
import CoreLocation

/// Asks for the position of the phone when the button is pressed.
@MainActor
final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var wanted: ((CLLocationCoordinate2D) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func locate(_ done: @escaping (CLLocationCoordinate2D) -> Void) {
        wanted = done
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if wanted != nil, manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in
            wanted?(c)
            wanted = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

struct ContentView: View {
    @StateObject private var model = AtlasModel()
    @StateObject private var catalog = MeshCatalog()
    @StateObject private var locator = Locator()

    @AppStorage("map") private var engine = Engine.arcgis
    @State private var query = ""
    @State private var places: [Place] = []
    @State private var showSettings = false
    @State private var showSaved = false
    @StateObject private var saved = SavedPlaces()
    @FocusState private var searching: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if engine == .arcgis {
                    ArcGISGlobe(model: model, catalog: catalog)
                } else {
                    AppleGlobe(model: model)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                searchBar
                if searching { results }
                if let error = catalog.error {
                    Text(error).font(.footnote).padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            // the compass shows only when the map is turned
            if !searching && abs(model.camera.heading.remainder(dividingBy: 360)) > 1 {
                RoundButton(symbol: "location.north.fill", label: "North up") { model.faceNorth() }
                    .rotationEffect(.degrees(-model.camera.heading))
                    .padding(.trailing, 14)
                    .padding(.top, 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            VStack(spacing: 12) {
                RoundButton(symbol: model.tilted ? "view.2d" : "view.3d", label: "2D or 3D") { model.toggleTilt() }
                RoundButton(symbol: "location.fill", label: "My location") {
                    locator.locate { c in
                        model.fly(to: Place(name: "My location", subtitle: "", latitude: c.latitude, longitude: c.longitude))
                    }
                }
            }
            .padding(.trailing, 14)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .sheet(item: $model.selected) { place in
            PlaceSheet(place: place, saved: saved)
                .presentationDetents([.height(190), .medium])
                .presentationBackgroundInteraction(.enabled)
        }
        .sheet(isPresented: $showSaved) {
            SavedList(saved: saved) { model.fly(to: $0) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: $engine, photoMeshes: catalog.photoMeshes, esri: catalog.esri) { model.fly(to: $0) }
        }
        .task { await catalog.load() }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    model.selected = nil
                    model.request = FlyRequest(latitude: model.camera.latitude, longitude: model.camera.longitude, distance: 18_000_000, tilted: false)
                } label: { Label("Whole Earth", systemImage: "globe.europe.africa") }
                Button {
                    if let m = catalog.esri.prefix(300).randomElement() { model.fly(to: m.place) }
                } label: { Label("Surprise me", systemImage: "dice") }
                Button {
                    model.selected = nil
                    showSaved = true
                } label: { Label("Saved places", systemImage: "bookmark") }
                Divider()
                Button {
                    searching = false
                    model.selected = nil
                    showSettings = true
                } label: { Label("Settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: "line.3.horizontal").font(.title3).frame(width: 28, height: 28)
            }
            .accessibilityLabel("Menu")
            TextField("Search", text: $query)
                .focused($searching)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { Task { await searchPlaces() } }
            if !query.isEmpty {
                Button {
                    query = ""
                    places = []
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private var results: some View {
        let found = catalog.search(query).map(\.place)
        return Group {
            if !places.isEmpty || !found.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(places) { row($0, symbol: "mappin.circle.fill") }
                        ForEach(found) { row($0, symbol: "cube.fill") }
                    }
                }
                .frame(maxHeight: 330)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private func row(_ place: Place, symbol: String) -> some View {
        Button {
            searching = false
            model.fly(to: place)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(place.name).lineLimit(1)
                    Text(place.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func searchPlaces() async {
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let response = try? await MKLocalSearch(request: request).start()
        places = (response?.mapItems.prefix(5) ?? []).map { item in
            Place(name: item.name ?? query, subtitle: item.placemark.title ?? "",
                  latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
        }
    }
}

struct RoundButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .accessibilityLabel(label)
    }
}

struct PlaceSheet: View {
    let place: Place
    @ObservedObject var saved: SavedPlaces

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(place.name).font(.title2.bold()).lineLimit(2)
            if !place.subtitle.isEmpty { Text(place.subtitle).foregroundStyle(.secondary) }
            Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                .font(.footnote.monospacedDigit())
                .textSelection(.enabled)
            HStack {
                Button {
                    saved.toggle(place)
                } label: {
                    Label(saved.saved(place) == nil ? "Save" : "Saved", systemImage: saved.saved(place) == nil ? "bookmark" : "bookmark.fill")
                }
                .buttonStyle(.bordered)
                if let url = URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f", place.latitude, place.longitude)) {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}
