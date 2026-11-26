// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import kotlinx.coroutines.launch
import com.arcgismaps.geometry.GeometryEngine
import com.arcgismaps.geometry.Polyline
import com.arcgismaps.mapping.symbology.SimpleLineSymbol
import com.arcgismaps.mapping.symbology.SimpleLineSymbolStyle
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.arcgismaps.Color
import com.arcgismaps.arcgisservices.LevelOfDetail
import com.arcgismaps.mapping.layers.TileInfo
import com.arcgismaps.geometry.Envelope
import com.arcgismaps.geometry.Point
import com.arcgismaps.geometry.Polygon
import com.arcgismaps.geometry.SpatialReference
import com.arcgismaps.mapping.symbology.ExtrusionMode
import com.arcgismaps.mapping.symbology.SimpleFillSymbol
import com.arcgismaps.mapping.symbology.SimpleFillSymbolStyle
import com.arcgismaps.mapping.symbology.SimpleRenderer
import com.arcgismaps.mapping.view.Graphic
import com.arcgismaps.mapping.view.GraphicsOverlay
import com.arcgismaps.mapping.view.SurfacePlacement
import com.arcgismaps.mapping.layers.TileImageFormat
import com.arcgismaps.mapping.ArcGISScene
import com.arcgismaps.mapping.ArcGISTiledElevationSource
import com.arcgismaps.mapping.Basemap
import com.arcgismaps.mapping.Surface
import com.arcgismaps.mapping.layers.IntegratedMeshLayer
import com.arcgismaps.mapping.layers.Layer
import com.arcgismaps.mapping.layers.Ogc3DTilesLayer
import com.arcgismaps.mapping.layers.WebTiledLayer
import com.arcgismaps.mapping.layers.WmsLayer
import com.arcgismaps.mapping.view.Camera
import com.arcgismaps.toolkit.geoviewcompose.SceneView
import com.arcgismaps.toolkit.geoviewcompose.SceneViewProxy
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.tan
import kotlin.time.Duration.Companion.seconds

/** The scene and what lies on it for the place looked at. */
class SceneHolder(private val aerial: List<AerialSource>) {
    // Sentinel-2 cloudless 2016 by EOX (CC BY 4.0): no key needed
    val scene = ArcGISScene(Basemap(WebTiledLayer.create("https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{level}/{row}/{col}.jpg"))).apply {
        baseSurface = Surface().apply {
            elevationSources.add(ArcGISTiledElevationSource("https://elevation3d.arcgis.com/arcgis/rest/services/WorldElevation3D/Terrain3D/ImageServer"))
        }
    }
    private val photos = mutableMapOf<String, Layer>()
    private val shown = mutableMapOf<String, Layer>()
    private val names by lazy {
        WebTiledLayer.create("https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/Reference_Labels/default/GoogleMapsCompatible_Level9/{level}/{row}/{col}.png")
    }

    private fun layer(source: AerialSource): Layer? {
        val template = source.template
        if (template.contains("{z}")) {
            return WebTiledLayer.create(template.replace("{z}", "{level}").replace("{y}", "{row}").replace("{x}", "{col}"))
        }
        if (template.contains("exportImage")) { // USGS: the same photos as a tiled service
            return WebTiledLayer.create("https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{level}/{row}/{col}")
        }
        // a map service (WMS): its address without the parts of one request, and the name of its layer
        val parts = template.split("?", limit = 2)
        if (parts.size < 2) return null
        val own = setOf("SERVICE", "VERSION", "REQUEST", "LAYERS", "STYLES", "CRS", "BBOX", "WIDTH", "HEIGHT", "FORMAT", "TRANSPARENT")
        val pairs = parts[1].split("&")
        val name = pairs.firstOrNull { it.startsWith("LAYERS=") }?.removePrefix("LAYERS=") ?: return null
        val rest = pairs.filter { it.substringBefore("=") !in own }.joinToString("&")
        return WmsLayer(if (rest.isEmpty()) parts[0] else parts[0] + "?" + rest, listOf(name))
    }

    // the past: a photo of the year, and buildings raised to their height (measured: orange, guessed: grey)
    private var past: Pair<String, Layer>? = null
    private val measured = blocks(Color.fromRgba(240, 150, 60, 255))
    private val guessed = blocks(Color.fromRgba(170, 175, 185, 255))
    // the streets with photos, in blue, lying on the ground
    private val streetOverlay = GraphicsOverlay().apply {
        sceneProperties.surfacePlacement = SurfacePlacement.DrapedFlat
        renderer = SimpleRenderer(SimpleLineSymbol(SimpleLineSymbolStyle.Solid, Color.fromRgba(26, 115, 255, 220), 5f))
    }
    val overlays = listOf(measured, guessed, streetOverlay)

    fun showStreets(streets: List<StreetLine>) {
        streetOverlay.graphics.clear()
        streets.forEach { street ->
            streetOverlay.graphics.add(Graphic(Polyline(street.map { Point(it.first, it.second, SpatialReference.wgs84()) })))
        }
    }

    private fun blocks(colour: Color) = GraphicsOverlay().apply {
        sceneProperties.surfacePlacement = SurfacePlacement.Relative
        renderer = SimpleRenderer(SimpleFillSymbol(SimpleFillSymbolStyle.Solid, colour)).apply {
            sceneProperties.extrusionMode = ExtrusionMode.BaseHeight
            sceneProperties.extrusionExpression = "[h]"
        }
    }

    fun showBuildings(buildings: List<OldBuilding>) {
        measured.graphics.clear()
        guessed.graphics.clear()
        buildings.forEach { b ->
            val outline = Polygon(b.ring.map { Point(it.first, it.second, SpatialReference.wgs84()) })
            (if (b.measured) measured else guessed).graphics.add(Graphic(outline, mapOf("h" to b.height)))
        }
    }

    private fun pastLayer(p: OldPicture): Layer {
        p.wmsLayer?.let { return WmsLayer(p.template, listOf(it)) }
        val template = p.template.replace("{z}", "{level}").replace("{y}", "{row}").replace("{x}", "{col}")
        // only the levels the service has: nearer than that, ArcGIS enlarges the last one
        val levels = (0..p.maxLevel).map { LevelOfDetail(it, 156543.03392804097 / (1 shl it), 591657527.591555 / (1 shl it)) }
        val mercator = SpatialReference.webMercator()
        val edge = 20037508.342789244
        val info = TileInfo(96, TileImageFormat.Jpg, levels, Point(-edge, edge, mercator), mercator, 256, 256)
        return WebTiledLayer.create(template, emptyList(), info, Envelope(-edge, -edge, edge, edge, spatialReference = mercator))
    }

    /** photos and 3D models for the camera; returns the credits of what is shown. year: look into the past */
    fun show(camera: CameraState, models: List<MeshModel>, placeNames: Boolean, year: Int?): List<String> {
        val picture = year?.let { History.picture(camera.latitude, camera.longitude, it) }
        if (past?.first != picture?.id) {
            past?.let { scene.operationalLayers.remove(it.second) }
            past = picture?.let { it.id to pastLayer(it) }
            past?.let { scene.operationalLayers.add(0, it.second) }
        }
        // today's close photos stay only where the year has none of its own
        val near = if (camera.distance < 20_000 && picture == null) aerial.filter { it.covers(camera.latitude, camera.longitude) }.take(1) else emptyList()
        photos.keys.filter { id -> near.none { it.id == id } }.forEach { id -> photos.remove(id)?.let { scene.operationalLayers.remove(it) } }
        near.filter { it.id !in photos }.forEach { source ->
            layer(source)?.let {
                photos[source.id] = it
                scene.operationalLayers.add(it)
            }
        }
        // the 3D models show today: not in the past
        val model = if (camera.distance < 5_000 && year == null) {
            models.firstOrNull { it.tiles3d && it.covers(camera.latitude, camera.longitude) }
                ?: models.firstOrNull { !it.tiles3d && it.covers(camera.latitude, camera.longitude) }
        } else null
        shown.keys.filter { it != model?.url }.forEach { url -> shown.remove(url)?.let { scene.operationalLayers.remove(it) } }
        if (model != null && model.url !in shown) {
            val l: Layer = if (model.tiles3d) Ogc3DTilesLayer(model.url) else IntegratedMeshLayer(model.url)
            shown[model.url] = l
            scene.operationalLayers.add(l)
        }
        val wantNames = placeNames && camera.distance > 40_000
        if (wantNames && names !in scene.operationalLayers) scene.operationalLayers.add(names)
        if (!wantNames && names in scene.operationalLayers) scene.operationalLayers.remove(names)
        return listOfNotNull(picture?.credit, year?.let { "Buildings: OpenHistoricalMap" }, model?.let { "${it.title} · ${it.owner}" }) + near.map { it.credit }
    }
}

/** the camera that looks at a place from `distance` metres: straight down, or tilted */
private fun cameraFor(latitude: Double, longitude: Double, distance: Double, heading: Double, tilted: Boolean): Camera {
    val pitch = if (tilted && distance < 100_000) 55.0 else 0.0
    val angle = Math.toRadians(pitch)
    val altitude = max(60.0, distance * cos(angle)) + 40
    val back = distance * sin(angle)
    val h = Math.toRadians(heading)
    val lat = latitude - back * cos(h) / 110_574
    val lon = longitude - back * sin(h) / (111_320 * max(0.1, cos(Math.toRadians(latitude))))
    return Camera(lat, lon, altitude, heading, pitch, 0.0)
}

/** the place in the middle of the picture */
private fun stateOf(camera: Camera): CameraState {
    val location = camera.location
    val altitude = max(1.0, location.z ?: 1.0)
    val pitch = Math.toRadians(min(80.0, max(0.0, camera.pitch)))
    val ahead = altitude * tan(pitch)
    val h = Math.toRadians(camera.heading)
    val lat = location.y + ahead * cos(h) / 110_574
    val lon = location.x + ahead * sin(h) / (111_320 * max(0.1, cos(Math.toRadians(location.y))))
    return CameraState(lat, lon, altitude / max(0.17, cos(pitch)), camera.heading)
}

@Composable
fun ArcGISMap(
    camera: CameraState, request: FlyRequest?, models: List<MeshModel>, placeNames: Boolean, year: Int?, buildings: List<OldBuilding>,
    streets: List<StreetLine>, onTap: (Double, Double) -> Unit,
    onCamera: (CameraState) -> Unit, onCredits: (List<String>) -> Unit, modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val holder = remember { SceneHolder(Data.aerial(context)) }
    val proxy = remember { SceneViewProxy() }
    val latest = remember { mutableStateOf<Camera?>(null) }
    val scope = rememberCoroutineScope()
    val tap by rememberUpdatedState(onTap)
    LaunchedEffect(streets) { holder.showStreets(streets) }
    SceneView(
        arcGISScene = holder.scene,
        modifier = modifier,
        sceneViewProxy = proxy,
        graphicsOverlays = holder.overlays,
        onSingleTapConfirmed = { event ->
            scope.launch {
                val ground = proxy.screenToBaseSurface(event.screenCoordinate) ?: return@launch
                val at = GeometryEngine.projectOrNull(ground, SpatialReference.wgs84()) as? Point ?: return@launch
                tap(at.y, at.x)
            }
        },
        onCurrentViewpointCameraChanged = { latest.value = it },
    )
    // coming from the other map: the same place
    LaunchedEffect(Unit) {
        proxy.setViewpointCameraAnimated(cameraFor(camera.latitude, camera.longitude, min(camera.distance, 20_000_000.0), camera.heading, camera.distance < 100_000), 0.1.seconds)
    }
    LaunchedEffect(request?.number) {
        request?.let { proxy.setViewpointCameraAnimated(cameraFor(it.latitude, it.longitude, it.distance, it.heading, it.tilted), 2.seconds) }
    }
    // layers change only when the camera rests: not while the fingers move
    LaunchedEffect(latest.value) {
        val now = latest.value ?: return@LaunchedEffect
        delay(450)
        val state = stateOf(now)
        if (abs(state.latitude - camera.latitude) > 0.001 || abs(state.longitude - camera.longitude) > 0.001 ||
            abs(state.distance - camera.distance) > camera.distance * 0.1 || abs(state.heading - camera.heading) > 2
        ) onCamera(state)
    }
    LaunchedEffect(camera, models.size, placeNames, year) { onCredits(holder.show(camera, models, placeNames, year)) }
    LaunchedEffect(buildings) { holder.showBuildings(buildings) }
}
