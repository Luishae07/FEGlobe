import Foundation

/// One 3D model of the Mesh Atlas: an Esri scene layer (integrated mesh) or a 3D Tiles photo mesh.
struct MeshModel: Identifiable, Decodable {
    let title: String
    let owner: String?
    let url: String
    let extent: [[Double]]
    let views: Double?
    let type: String?

    var id: String { url }
    var is3DTiles: Bool { type == "3dt" }
    var west: Double { extent[0][0] }
    var south: Double { extent[0][1] }
    var east: Double { extent[1][0] }
    var north: Double { extent[1][1] }

    enum CodingKeys: String, CodingKey {
        case title = "t", owner = "o", url = "u", extent = "e", views = "v", type
    }

    func covers(latitude: Double, longitude: Double) -> Bool {
        longitude >= west && longitude <= east && latitude >= south && latitude <= north
    }

    var place: Place {
        let widthMetres = max(300, (east - west) * 111_320 * cos((north + south) / 2 * .pi / 180))
        return Place(name: title, subtitle: owner ?? "", latitude: (north + south) / 2, longitude: (east + west) / 2,
                     distance: min(6000, widthMetres * 0.8))
    }
}

/// A broken entry of the list is skipped instead of losing the whole list.
private struct Lossy: Decodable {
    let model: MeshModel?
    init(from decoder: Decoder) throws {
        let m = try? MeshModel(from: decoder)
        model = (m?.extent.count ?? 0) >= 2 && m?.extent.allSatisfy({ $0.count >= 2 }) == true ? m : nil
    }
}

/// The lists of the Mesh Atlas: photo meshes (sources.json) and the Esri scene layers (scans.json). They are fetched when the app starts and kept in memory only.
@MainActor
final class MeshCatalog: ObservableObject {
    @Published private(set) var photoMeshes: [MeshModel] = []
    @Published private(set) var esri: [MeshModel] = []
    @Published private(set) var error: String?

    private static let base = "https://mesh.flowsearch.org/"

    func load() async {
        do {
            photoMeshes = try await Self.fetch("sources.json")
            esri = try await Self.fetch("scans.json").sorted { ($0.views ?? 0) > ($1.views ?? 0) }
            error = nil
        } catch {
            self.error = "The list of 3D models could not be loaded: \(error.localizedDescription)"
        }
    }

    private static func fetch(_ name: String) async throws -> [MeshModel] {
        guard let url = URL(string: base + name) else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Lossy].self, from: data).compactMap(\.model)
    }

    /// The models to show at a place: the photo mesh of the city if there is one, else the most viewed Esri layers there.
    func models(latitude: Double, longitude: Double, limit: Int = 2) -> [MeshModel] {
        if let photo = photoMeshes.first(where: { $0.covers(latitude: latitude, longitude: longitude) }) {
            return [photo]
        }
        return Array(esri.lazy.filter { $0.covers(latitude: latitude, longitude: longitude) }.prefix(limit))
    }

    func search(_ text: String, limit: Int = 8) -> [MeshModel] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return [] }
        return Array((photoMeshes + esri).lazy.filter { $0.title.localizedCaseInsensitiveContains(q) }.prefix(limit))
    }
}
