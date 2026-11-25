// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import CoreLocation

/// A building of the past (OpenHistoricalMap).
struct OldBuilding: Identifiable, Sendable {
    let id = UUID()
    let ring: [CLLocationCoordinate2D]
    let from: Int?
    let to: Int?
    let height: Double
    let measured: Bool

    /// a building counts for the year it was built and for the year it disappeared
    func stands(in year: Int) -> Bool { (from.map { $0 <= year } ?? true) && (to.map { $0 >= year } ?? true) }
}

/// Photos of the past. template: tiles with {z} {x} {y}; or a map service (WMS) with its layer.
struct OldPicture: Equatable {
    let id: String
    let label: String
    let credit: String
    let template: String
    var maxLevel = 18
    var wmsLayer: String? = nil
}

enum History {
    static let firstYear = 1850
    static var lastYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }
    /// the camera must be this near, in metres, for buildings to be loaded
    static let near = 5_000.0

    /// the photos for a place and a year, or nil: then only today's picture exists
    static func picture(latitude: Double, longitude: Double, year: Int) -> OldPicture? {
        func inside(_ west: Double, _ south: Double, _ east: Double, _ north: Double) -> Bool {
            longitude >= west && longitude <= east && latitude >= south && latitude <= north
        }
        if (1945...1965).contains(year) && inside(13.08, 52.33, 13.77, 52.68) {
            return OldPicture(id: "berlin1953", label: "Aerial photos of Berlin, 1953", credit: "Geoportal Berlin, Luftbilder 1953 (dl-de/zero-2-0)",
                              template: "https://gdi.berlin.de/services/wms/luftbild_1953_22", wmsLayer: "c_luftbilder_1953_22_raster")
        }
        if year >= 1946 && year < lastYear && inside(5.9, 45.8, 10.5, 47.8) {
            return OldPicture(id: "swiss\(year)", label: "Aerial photos of Switzerland, \(year) (where flown)", credit: "swisstopo, SWISSIMAGE time travel",
                              template: "https://wmts.geo.admin.ch/1.0.0/ch.swisstopo.swissimage-product/default/\(year)/3857/{z}/{x}/{y}.jpeg")
        }
        if (1950...1964).contains(year) && inside(-9.4, 36.0, 3.2, 42.4) {
            return OldPicture(id: "spain1956", label: "Aerial photos of Spain, 1956–57", credit: "© Instituto Geográfico Nacional de España (CC BY 4.0)",
                              template: "https://www.ign.es/wms/pnoa-historico", wmsLayer: "AMS_1956-1957")
        }
        if (1945...1968).contains(year) && inside(-5.2, 42.3, 8.3, 51.1) {
            return OldPicture(id: "france1950", label: "Aerial photos of France, 1950–65", credit: "IGN France (Licence Ouverte)",
                              template: "https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=ORTHOIMAGERY.ORTHOPHOTOS.1950-1965&STYLE=normal&TILEMATRIXSET=PM&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&FORMAT=image/png")
        }
        // the whole world from space: the yearly Landsat pictures of NASA, 30 m to a point
        let landsat = [1985, 1990, 2000].min { abs($0 - year) < abs($1 - year) } ?? 2000
        if abs(landsat - year) <= 2 {
            return OldPicture(id: "landsat\(landsat)", label: "Landsat satellite picture, about \(landsat)", credit: "NASA GIBS, Landsat WELD",
                              template: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/Landsat_WELD_CorrectedReflectance_TrueColor_Global_Annual/default/\(landsat - 1)-12-01/GoogleMapsCompatible_Level12/{z}/{y}/{x}.jpg", maxLevel: 12)
        }
        return nil
    }

    private struct Answer: Decodable {
        struct Spot: Decodable { let lat: Double; let lon: Double }
        struct Member: Decodable { let role: String?; let geometry: [Spot?]? }
        struct Element: Decodable { let tags: [String: String]?; let geometry: [Spot?]?; let members: [Member]? }
        let elements: [Element]
    }

    private static func year(of date: String?) -> Int? {
        guard let date, let range = date.range(of: "^~?\\s*\\d{3,4}", options: .regularExpression) else { return nil }
        return Int(date[range].filter(\.isNumber))
    }

    private static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        return Double(text.replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces))
    }

    /// all buildings of all times around a place; radius in metres
    static func buildings(latitude: Double, longitude: Double, radius: Double) async throws -> [OldBuilding] {
        let dLat = radius / 110_574
        let dLon = radius / (111_320 * max(0.1, cos(latitude * .pi / 180)))
        let box = "\(latitude - dLat),\(longitude - dLon),\(latitude + dLat),\(longitude + dLon)"
        let query = "[out:json][timeout:30];(way[\"building\"](\(box));relation[\"building\"](\(box)););out geom 5000;"
        var request = URLRequest(url: URL(string: "https://overpass-api.openhistoricalmap.org/api/interpreter")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Atlas-iOS", forHTTPHeaderField: "User-Agent")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        request.httpBody = Data(("data=" + encoded).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var result: [OldBuilding] = []
        for element in try JSONDecoder().decode(Answer.self, from: data).elements {
            guard let tags = element.tags else { continue }
            // the outlines: of a way itself, or of the outer parts of a relation
            let outlines: [[Answer.Spot?]] = element.geometry.map { [$0] }
                ?? (element.members ?? []).filter { $0.role == "outer" }.compactMap(\.geometry)
            let stated = number(tags["height"])
            let floors = number(tags["building:levels"])
            for outline in outlines {
                let ring = outline.compactMap { $0.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
                guard ring.count >= 4, ring.first?.latitude == ring.last?.latitude, ring.first?.longitude == ring.last?.longitude else { continue }
                result.append(OldBuilding(ring: ring, from: year(of: tags["start_date"]), to: year(of: tags["end_date"]),
                                          height: stated ?? floors.map { $0 * 3 } ?? 9, measured: stated != nil || floors != nil))
            }
        }
        return result
    }
}

/// The year looked at, and what is loaded about it around the camera.
@MainActor
final class Past: ObservableObject {
    @Published var year: Int?
    @Published private(set) var shown: [OldBuilding] = []
    @Published private(set) var status = ""
    /// changes whenever `shown` changes
    @Published private(set) var version = 0

    private var loaded: [OldBuilding] = []
    private var middle: CLLocationCoordinate2D?
    private var task: Task<Void, Never>?

    /// to call when the year or the camera changed; buildings are loaded again only after a real move
    func update(_ camera: CameraState) {
        task?.cancel()
        guard year != nil else {
            show([], "")
            return
        }
        guard camera.distance < History.near else {
            show([], "Zoom in to a few streets to see buildings.")
            return
        }
        let moved = middle.map {
            abs($0.latitude - camera.latitude) * 110_574 > 350
                || abs($0.longitude - camera.longitude) * 111_320 * cos(camera.latitude * .pi / 180) > 350
        } ?? true
        if !moved {
            filter()
            return
        }
        task = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            status = "Loading buildings…"
            do {
                let found = try await History.buildings(latitude: camera.latitude, longitude: camera.longitude, radius: 900)
                if Task.isCancelled { return }
                loaded = found
                middle = CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude)
                filter()
            } catch {
                if !Task.isCancelled { status = "The buildings could not be loaded. Move the map to try again." }
            }
        }
    }

    private func filter() {
        guard let year else { return }
        let found = loaded.filter { $0.stands(in: year) }
        show(found, found.isEmpty ? "No buildings of this year are mapped here."
            : "\(found.count) buildings, \(found.filter { !$0.measured }.count) with a guessed height (grey).")
    }

    private func show(_ buildings: [OldBuilding], _ text: String) {
        shown = buildings
        status = text
        version += 1
    }
}

struct TimePanel: View {
    @ObservedObject var past: Past
    let camera: CameraState
    let apple: Bool
    @State private var slider = 2000.0

    var body: some View {
        let year = past.year ?? 2000
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Button { past.year = max(History.firstYear, year - 1) } label: { Image(systemName: "minus.circle.fill").font(.title2) }
                Text(String(Int(slider.rounded()))).font(.title.bold().monospacedDigit())
                Button { past.year = min(History.lastYear, year + 1) } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                Spacer()
                Button("Today") { past.year = nil }
            }
            // the maps change when the finger lets go
            Slider(value: $slider, in: Double(History.firstYear)...Double(History.lastYear)) { editing in
                if !editing { past.year = Int(slider.rounded()) }
            }
            Text(past.status).font(.footnote)
            Text(apple ? "Apple Maps shows flat outlines on today's map. ArcGIS shows 3D and old pictures."
                 : History.picture(latitude: camera.latitude, longitude: camera.longitude, year: year)?.label
                    ?? "No old picture for this year here: the ground shows today.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .onAppear { slider = Double(year) }
        .onChange(of: past.year) { _, new in if let new { slider = Double(new) } }
    }
}
