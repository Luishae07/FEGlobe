// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// A place that the user kept.
struct SavedPlace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var distance: Double

    var place: Place { Place(name: name, subtitle: "Saved place", latitude: latitude, longitude: longitude, distance: distance) }
}

/// The saved places, kept on the phone only.
@MainActor
final class SavedPlaces: ObservableObject {
    private static let key = "savedPlaces"
    @Published private(set) var all: [SavedPlace] {
        didSet {
            if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        all = data.flatMap { try? JSONDecoder().decode([SavedPlace].self, from: $0) } ?? []
    }

    func saved(_ p: Place) -> SavedPlace? {
        all.first { abs($0.latitude - p.latitude) < 0.00001 && abs($0.longitude - p.longitude) < 0.00001 }
    }

    func toggle(_ p: Place) {
        if let old = saved(p) {
            all.removeAll { $0.id == old.id }
        } else {
            all.append(SavedPlace(name: p.name, latitude: p.latitude, longitude: p.longitude, distance: p.distance))
        }
    }

    func remove(at offsets: IndexSet) {
        all.remove(atOffsets: offsets)
    }
}

struct SavedList: View {
    @ObservedObject var saved: SavedPlaces
    let open: (Place) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(saved.all) { s in
                    Button {
                        dismiss()
                        open(s.place)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text(String(format: "%.4f, %.4f", s.latitude, s.longitude)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { saved.remove(at: $0) }
            }
            .overlay {
                if saved.all.isEmpty {
                    ContentUnavailableView("No saved places", systemImage: "bookmark", description: Text("Search a place and press Save."))
                }
            }
            .navigationTitle("Saved places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
