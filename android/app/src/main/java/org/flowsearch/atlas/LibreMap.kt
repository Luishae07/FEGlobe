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
fun LibreMap(camera: CameraState, request: FlyRequest?, onCamera: (CameraState) -> Unit, onCredits: (List<String>) -> Unit, modifier: Modifier = Modifier) {
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
            map = m
        }
        view
    }, modifier = modifier)
    LaunchedEffect(request?.number, map) {
        val m = map ?: return@LaunchedEffect
        request?.let { m.animateCamera(CameraUpdateFactory.newCameraPosition(position(it.latitude, it.longitude, it.distance, it.heading, it.tilted)), 1800) }
    }
    LaunchedEffect(Unit) { onCredits(listOf("OpenFreeMap © OpenMapTiles, data from OpenStreetMap")) }
}
