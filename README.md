# Atlas for iPhone, and FEGlobe

The Mesh Atlas as an iPhone and iPad app (SwiftUI, iOS 17 or later): a full-screen globe, search for places and 3D models, saved places, my location, sharing.

## FEGlobe (`FEGlobe/`)

Our own Metal globe engine:

- Sentinel-2 satellite tiles on a sphere, finer where you are near; terrain; sunlight with city lights at night; place names.
- 3D models near the ground: Esri scene layers (I3S integrated meshes, versions 1.4 to 1.7+, geographic and UTM) and a glTF model service (used for the photo meshes).
- Gestures: move, pinch, rotate, tilt with two fingers, double tap; smooth flights.
- Draws only when something changed, frees its memory when the phone asks.

```swift
import FEGlobe

@State private var camera = GlobeCamera(latitude: 40.7484, longitude: -73.9857, distance: 900, tilt: 60)

FEGlobeView(camera: $camera, models: [GlobeModel(id: "ny", name: "New York", kind: .sceneLayer(sceneServerURL))])
```

Known limits: Draco-only scene layers are not read; other coordinate systems than geographic and UTM are refused; one model area (about 260 m around the middle) at a time;
model heights are set onto the terrain, so they are not survey heights.

The app can also use **Apple MapKit** (Settings).

## Build

With a Mac: `brew install xcodegen`, (the app icon is drawn from Natural Earth by `tools/icon`), `xcodegen`, open `Atlas.xcodeproj`, choose your Apple ID as the team, run on your phone.

Without a Mac: add the repository to [CircleCI](https://circleci.com); `.circleci/config.yml` builds `Atlas.ipa` (not signed, under the job's artifacts) and tests the engine. Install the file with Sideloadly or AltStore. With a free Apple ID it runs for 7 days.

## Licences

- `FEGlobe/`: GNU AGPL-3.0 or later with an App Store exception (`FEGlobe/LICENSE`, `FEGlobe/APPSTORE-EXCEPTION.md`).
- The app (everything else): Mozilla Public License 2.0 (`LICENSE`).
- A built app contains the engine, so whoever distributes it also has to meet the terms of the AGPL.
- Map data keeps its own licence: the imagery is VersaTiles satellite (openly licensed aerial photos and satellite mosaics, [sources](https://versatiles.org/sources/)). The 3D models belong to their owners.
