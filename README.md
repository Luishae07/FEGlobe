# Atlas for iPhone

The Mesh Atlas as an iPhone and iPad app (SwiftUI, iOS 18 or later): a 3D globe, search for places and 3D models, saved places, my location, sharing.

- Map engine: **ArcGIS Maps SDK for Swift** (Esri's, not open source).
- Pictures: Sentinel-2 cloudless 2016 by EOX; close up, official aerial photos (`Resources/aerial.json`).
- 3D: the Esri scene layers and photo meshes of mesh.flowsearch.org.

`FEGlobe/` is a separate open source globe engine of this repository (AGPL-3.0). The app does not use or include it.

## Build

You need your own ArcGIS licence string (free Lite level, from Esri). Write it into `Sources/Secrets.swift` (this file is not committed):

```swift
let arcgisLicense = "runtimelite,..."
```

Then: `brew install xcodegen`, `xcodegen`, open `Atlas.xcodeproj` and run.

## Licences

- The app's own code: Mozilla Public License 2.0 (`LICENSE`).
- ArcGIS Maps SDK: Esri's licence.
- `FEGlobe/`: AGPL-3.0 or later with an App Store exception.
- Data keeps its own licence, see `DATA.md`.
