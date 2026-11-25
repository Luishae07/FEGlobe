# Atlas

The Mesh Atlas as an app for iPhone, iPad and Android: a 3D globe, search for places and 3D models, saved places, my location, sharing. Download: https://mesh.flowsearch.org/app/

## iPhone and iPad (SwiftUI, iOS 18 or later)

- Maps: **ArcGIS Maps SDK for Swift** (Esri's, not open source), or **Apple Maps** (Settings).
- Pictures: Sentinel-2 cloudless 2016 by EOX; close up, official aerial photos (`Resources/aerial.json`).
- 3D: the Esri scene layers and photo meshes of mesh.flowsearch.org.

`FEGlobe/` is a separate open source globe engine of this repository (AGPL-3.0). The app does not use or include it.

## Build

You need your own ArcGIS licence string (free Lite level, from Esri). Write it into `Sources/Secrets.swift` (this file is not committed):

```swift
let arcgisLicense = "runtimelite,..."
```

Then: `brew install xcodegen`, `xcodegen`, open `Atlas.xcodeproj` and run.

## Android (Kotlin, Jetpack Compose, Android 9 or later, 64-bit ARM)

In `android/`. Maps: **ArcGIS Maps SDK for Kotlin**, or **MapLibre** with OpenFreeMap (Settings). Photos and 3D models as above (the models only in ArcGIS mode).

Build with the Android SDK (platform 36) and Gradle 9: set `ANDROID_HOME`, `GRADLE`, `ARCGIS_LICENSE`, and `ATLAS_KEYSTORE` (a signing key with the alias `atlas`) with `ATLAS_KEYSTORE_PASSWORD`, then run `android/build.sh`.

## Licences

- The app's own code: Mozilla Public License 2.0 (`LICENSE`).
- ArcGIS Maps SDK: Esri's licence.
- `FEGlobe/`: AGPL-3.0 or later with an App Store exception.
- Data keeps its own licence, see `DATA.md`.
