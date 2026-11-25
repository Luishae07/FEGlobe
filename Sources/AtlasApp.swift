// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import ArcGIS

@main
struct AtlasApp: App {
    init() {
        // the Lite licence of the ArcGIS Maps SDK: written into Secrets.swift when the app is built, not part of the source code
        if let key = LicenseKey(arcgisLicense) {
            do {
                try ArcGISEnvironment.setLicense(with: key)
            } catch {
                print("ArcGIS licence not accepted: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
