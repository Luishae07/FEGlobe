// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.FillExtrusionLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.layers.RasterLayer
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.android.style.sources.RasterSource
import org.maplibre.android.style.sources.TileSet
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

// MapLibre counts in zoom levels, the app in metres from the camera
private fun zoomFor(distance: Double, latitude: Double) = min(19.0, max(1.0, ln(40_000_000.0 * cos(Math.toRadians(latitude)) / max(50.0, distance)) / ln(2.0) + 0.5))
private fun distanceFor(zoom: Double, latitude: Double) = 40_000_000.0 * cos(Math.toRadians(latitude)) / 2.0.pow(zoom - 0.5)

private fun position(latitude: Double, longitude: Double, distance: Double, heading: Double, tilted: Boolean) =
    CameraPosition.Builder().target(LatLng(latitude, longitude)).zoom(zoomFor(distance, latitude))
        .bearing(heading).tilt(if (tilted && distance < 20_000) 55.0 else 0.0).build()

/** The second map: MapLibre with the open style of OpenFreeMap (streets, names, 3D buildings; no key). */
@Composable
fun LibreMap(
    camera: CameraState, request: FlyRequest?, year: Int?, buildings: List<OldBuilding>, streets: List<StreetLine>, onTap: (Double, Double) -> Unit,
    onCamera: (CameraState) -> Unit, onCredits: (List<String>) -> Unit, modifier: Modifier = Modifier,
) {
    val tap by rememberUpdatedState(onTap)
    val context = LocalContext.current
    val report by rememberUpdatedState(onCamera)
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    val view = remember {
        MapLibre.getInstance(context)
        MapView(context).apply { onCreate(null) }
    }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> view.onStart()
                Lifecycle.Event.ON_RESUME -> view.onResume()
                Lifecycle.Event.ON_PAUSE -> view.onPause()
                Lifecycle.Event.ON_STOP -> view.onStop()
                else -> {}
            }
        }
        owner.lifecycle.addObserver(observer)
        onDispose {
            owner.lifecycle.removeObserver(observer)
            view.onPause()
            view.onStop()
            view.onDestroy()
        }
    }
    AndroidView(factory = {
        view.getMapAsync { m ->
            m.setStyle("https://tiles.openfreemap.org/styles/liberty")
            m.cameraPosition = position(camera.latitude, camera.longitude, camera.distance, camera.heading, camera.distance < 20_000)
            m.uiSettings.isCompassEnabled = false
            m.uiSettings.isLogoEnabled = false
            m.addOnCameraIdleListener {
                val p = m.cameraPosition
                val at = p.target ?: return@addOnCameraIdleListener
                report(CameraState(at.latitude, at.longitude, distanceFor(p.zoom, at.latitude), p.bearing))
            }
            m.addOnMapClickListener { p ->
                tap(p.latitude, p.longitude)
                false
            }
            map = m
        }
        view
    }, modifier = modifier)
    LaunchedEffect(request?.number, map) {
        val m = map ?: return@LaunchedEffect
        request?.let { m.animateCamera(CameraUpdateFactory.newCameraPosition(position(it.latitude, it.longitude, it.distance, it.heading, it.tilted)), 1800) }
    }
    val picture = year?.let { History.picture(camera.latitude, camera.longitude, it) }
    LaunchedEffect(map, picture?.id, year != null) {
        map?.getStyle { style -> showPast(style, picture, year != null) }
        onCredits(listOfNotNull(picture?.credit, year?.let { "Buildings: OpenHistoricalMap" }, "OpenFreeMap © OpenMapTiles, data from OpenStreetMap"))
    }
    LaunchedEffect(map, buildings) { map?.getStyle { style -> showBuildings(style, buildings) } }
    LaunchedEffect(map, streets) { map?.getStyle { style -> showStreets(style, streets) } }
}

/** the streets with photos, in blue */
private fun showStreets(style: Style, streets: List<StreetLine>) {
    val lines = JSONArray()
    streets.forEach { street ->
        val line = JSONArray()
        street.forEach { line.put(JSONArray().put(it.first).put(it.second)) }
        lines.put(line)
    }
    val data = JSONObject().put("type", "Feature").put("properties", JSONObject())
        .put("geometry", JSONObject().put("type", "MultiLineString").put("coordinates", lines)).toString()
    val source = style.getSourceAs<GeoJsonSource>("streets")
    if (source != null) {
        source.setGeoJson(data)
    } else {
        style.addSource(GeoJsonSource("streets", data))
        style.addLayer(LineLayer("streets", "streets").withProperties(
            PropertyFactory.lineColor(Panoramax.BLUE), PropertyFactory.lineWidth(5f), PropertyFactory.lineOpacity(0.85f),
            PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
        ))
    }
}

/** the photo of the year under the names, and today's buildings hidden while looking into the past */
private fun showPast(style: Style, picture: OldPicture?, past: Boolean) {
    style.layers.filter { it.id.startsWith("building") }.forEach {
        it.setProperties(PropertyFactory.visibility(if (past) Property.NONE else Property.VISIBLE))
    }
    style.removeLayer("old-picture")
    style.removeSource("old-picture")
    if (picture == null) return
    val template = if (picture.wmsLayer == null) picture.template else
        "${picture.template}?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=${picture.wmsLayer}&STYLES=&CRS=EPSG:3857&BBOX={bbox-epsg-3857}&WIDTH=256&HEIGHT=256&FORMAT=image/png&TRANSPARENT=TRUE"
    val tiles = TileSet("2.2.0", template).apply { setMaxZoom(picture.maxLevel.toFloat()) }
    style.addSource(RasterSource("old-picture", tiles, 256))
    val layer = RasterLayer("old-picture", "old-picture")
    val under = if (style.getLayer("old-buildings") != null) "old-buildings" else style.layers.firstOrNull { it is SymbolLayer }?.id
    if (under != null) style.addLayerBelow(layer, under) else style.addLayer(layer)
}

private fun showBuildings(style: Style, buildings: List<OldBuilding>) {
    val features = JSONArray()
    buildings.forEach { b ->
        val ring = JSONArray()
        b.ring.forEach { ring.put(JSONArray().put(it.first).put(it.second)) }
        features.put(JSONObject().put("type", "Feature")
            .put("properties", JSONObject().put("h", b.height).put("c", if (b.measured) "#f0963c" else "#aaafb9"))
            .put("geometry", JSONObject().put("type", "Polygon").put("coordinates", JSONArray().put(ring))))
    }
    val data = JSONObject().put("type", "FeatureCollection").put("features", features).toString()
    val source = style.getSourceAs<GeoJsonSource>("old-buildings")
    if (source != null) {
        source.setGeoJson(data)
    } else {
        style.addSource(GeoJsonSource("old-buildings", data))
        style.addLayer(FillExtrusionLayer("old-buildings", "old-buildings").withProperties(
            PropertyFactory.fillExtrusionHeight(Expression.get("h")),
            PropertyFactory.fillExtrusionColor(Expression.toColor(Expression.get("c"))),
            PropertyFactory.fillExtrusionOpacity(0.92f),
        ))
    }
}
