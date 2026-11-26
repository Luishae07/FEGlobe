// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.arcgismaps.ArcGISEnvironment
import com.arcgismaps.LicenseKey
import kotlinx.coroutines.launch
import kotlin.math.abs

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ArcGISEnvironment.applicationContext = applicationContext
        // the Lite licence of the ArcGIS Maps SDK: put in when the app is built, not part of the source code
        LicenseKey.create(BuildConfig.ARCGIS_LICENSE)?.let { ArcGISEnvironment.setLicense(it) }
        enableEdgeToEdge()
        setContent { AtlasTheme { AtlasScreen() } }
    }
}

/** Material You: the colours of the phone. */
@Composable
fun AtlasTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colours = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colours, content = content)
}

@SuppressLint("MissingPermission")
private fun locate(context: Context, found: (Double, Double) -> Unit) {
    val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    val providers = manager.getProviders(true)
    val provider = listOf("fused", LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER).firstOrNull { it in providers }
    if (provider == null) {
        Toast.makeText(context, "Location is switched off", Toast.LENGTH_SHORT).show()
    } else if (Build.VERSION.SDK_INT >= 30) {
        manager.getCurrentLocation(provider, null, context.mainExecutor) { l ->
            if (l != null) found(l.latitude, l.longitude) else Toast.makeText(context, "No position yet", Toast.LENGTH_SHORT).show()
        }
    } else {
        manager.getLastKnownLocation(provider)?.let { found(it.latitude, it.longitude) }
    }
}

enum class Page { Map, Settings, Saved }

@Composable
fun AtlasScreen() {
    val context = LocalContext.current
    val store = remember { Store(context) }
    val scope = rememberCoroutineScope()
    var page by remember { mutableStateOf(Page.Map) }
    var useLibre by remember { mutableStateOf(store.useMapLibre) }
    var placeNames by remember { mutableStateOf(store.placeNames) }
    var saved by remember { mutableStateOf(store.saved) }
    var camera by remember { mutableStateOf(CameraState()) }
    var request by remember { mutableStateOf<FlyRequest?>(null) }
    var selected by remember { mutableStateOf<Place?>(null) }
    var tilted by remember { mutableStateOf(true) }
    var credits by remember { mutableStateOf(listOf<String>()) }
    var photo by remember { mutableStateOf(listOf<MeshModel>()) }
    var esri by remember { mutableStateOf(listOf<MeshModel>()) }
    var year by remember { mutableStateOf<Int?>(null) } // null: today
    val past = rememberPast(year, camera)
    // street view: blue streets have photos, a tap on one opens it
    var street by remember { mutableStateOf(false) }
    var coverage by remember { mutableStateOf(Coverage()) }
    var streetStatus by remember { mutableStateOf("") }
    var picture by remember { mutableStateOf<StreetPicture?>(null) }
    val streetNear = camera.distance < Panoramax.NEAR
    // blue at every zoom (MapLibre reads the tiles itself; for ArcGIS they are read here)
    val tiles = if (street && !useLibre) Panoramax.view(camera.latitude, camera.longitude, camera.distance) else null
    LaunchedEffect(tiles) {
        if (tiles == null) return@LaunchedEffect
        kotlinx.coroutines.delay(150)
        coverage = Panoramax.coverage(tiles)
        streetStatus = if (coverage.isEmpty) "No street photos around here." else ""
    }
    fun tapped(latitude: Double, longitude: Double) {
        if (!street) return
        if (camera.distance >= Panoramax.NEAR) { // from far away a tap flies closer
            request = FlyRequest(System.nanoTime(), latitude, longitude, (camera.distance / 8).coerceAtLeast(900.0), camera.heading, false)
            return
        }
        scope.launch {
            streetStatus = "Opening…"
            val result = runCatching { Panoramax.nearest(latitude, longitude, (camera.distance * 0.04).coerceIn(30.0, 150.0)) }
            picture = result.getOrNull()
            streetStatus = when {
                result.isFailure -> "The photos could not be loaded."
                picture == null -> "No photo there. Tap on a blue street."
                else -> ""
            }
        }
    }

    LaunchedEffect(Unit) {
        runCatching {
            photo = Data.models("sources.json")
            esri = Data.models("scans.json")
        }.onFailure { Toast.makeText(context, "The list of 3D models could not be loaded", Toast.LENGTH_LONG).show() }
    }

    fun go(latitude: Double, longitude: Double, distance: Double, heading: Double = 0.0, tilt: Boolean = tilted) {
        request = FlyRequest(System.nanoTime(), latitude, longitude, distance, heading, tilt)
    }
    fun flyTo(place: Place) {
        selected = place
        page = Page.Map
        go(place.latitude, place.longitude, place.distance)
    }
    fun myPlace() = locate(context) { a, o -> go(a, o, 1500.0) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { answers ->
        if (answers.values.any { it }) myPlace()
    }

    Box(Modifier.fillMaxSize()) {
        // the map stays alive behind the other pages
        if (useLibre) {
            LibreMap(camera, request, year, past.shown, street, onTap = ::tapped,
                onCamera = { camera = it }, onCredits = { credits = it }, modifier = Modifier.fillMaxSize())
        } else {
            ArcGISMap(camera, request, photo + esri, placeNames, year, past.shown, if (street) coverage else Coverage(), onTap = ::tapped,
                onCamera = { camera = it }, onCredits = { credits = it }, modifier = Modifier.fillMaxSize())
        }

        Column(Modifier.statusBarsPadding().padding(horizontal = 14.dp, vertical = 6.dp).align(Alignment.TopCenter)) {
            SearchPill(
                esri = photo + esri,
                near = camera,
                onPlace = { flyTo(it) },
                onWhole = {
                    selected = null
                    go(camera.latitude, camera.longitude, 18_000_000.0, tilt = false)
                },
                onSurprise = { esri.take(300).randomOrNull()?.let { flyTo(it.place) } },
                onSaved = { page = Page.Saved },
                onSettings = { page = Page.Settings },
            )
            if (abs(camera.heading % 360) > 1) {
                SmallFloatingActionButton(onClick = { go(camera.latitude, camera.longitude, camera.distance) }, modifier = Modifier.align(Alignment.End).padding(top = 10.dp)) {
                    Icon(Icons.Filled.Navigation, "North up", Modifier.rotate(-camera.heading.toFloat()))
                }
            }
        }

        Column(Modifier.align(Alignment.BottomEnd).navigationBarsPadding().padding(end = 14.dp, bottom = if (selected != null) 190.dp else if (year != null) 230.dp else if (street) 120.dp else 40.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FloatingActionButton(
                onClick = {
                    street = !street
                    streetStatus = ""
                    if (street) {
                        selected = null
                        year = null
                        // from above: blue streets are easy to hit; the zoom stays as it is
                        go(camera.latitude, camera.longitude, camera.distance, camera.heading, tilt = false)
                    }
                },
                containerColor = if (street) androidx.compose.ui.graphics.Color(0xFF1A73FF) else FloatingActionButtonDefaults.containerColor,
                contentColor = if (street) androidx.compose.ui.graphics.Color.White else MaterialTheme.colorScheme.onPrimaryContainer,
            ) { Icon(Icons.AutoMirrored.Filled.DirectionsWalk, "Street view") }
            FloatingActionButton(onClick = {
                if (year == null) {
                    selected = null
                    street = false
                    year = 2000
                } else year = null
            }) { Icon(Icons.Filled.History, "Past years") }
            FloatingActionButton(onClick = {
                tilted = !tilted
                go(camera.latitude, camera.longitude, camera.distance, camera.heading, tilted)
            }) { Text(if (tilted) "2D" else "3D", style = MaterialTheme.typography.titleMedium) }
            FloatingActionButton(onClick = {
                val granted = context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
                if (granted) myPlace() else permission.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION))
            }) { Icon(Icons.Filled.MyLocation, "My location") }
        }

        if (street && selected == null) {
            Card(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(10.dp).fillMaxWidth(), shape = RoundedCornerShape(24.dp)) {
                Row(Modifier.padding(start = 18.dp, end = 8.dp, top = 10.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.AutoMirrored.Filled.DirectionsWalk, null, tint = androidx.compose.ui.graphics.Color(0xFF1A73FF))
                    Column(Modifier.weight(1f).padding(start = 14.dp)) {
                        Text(if (streetNear) "Tap a blue street" else "Tap a blue area to fly closer", style = MaterialTheme.typography.titleMedium)
                        Text(streetStatus.ifEmpty { "Photos: Panoramax" }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = { street = false }) { Icon(Icons.Filled.Close, "Close street view") }
                }
            }
        }

        year?.let { y ->
            if (selected == null) {
                TimePanel(y, camera, past.status, onYear = { year = it }, onClose = { year = null },
                    modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(10.dp))
            }
        }

        if (credits.isNotEmpty() && selected == null && year == null && !street) {
            Text("© " + credits.first(), fontSize = 9.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, color = androidx.compose.ui.graphics.Color.White,
                modifier = Modifier.align(Alignment.BottomStart).navigationBarsPadding().padding(start = 10.dp, bottom = 22.dp).widthIn(max = 260.dp))
        }

        selected?.let { place ->
            val isSaved = saved.any { abs(it.latitude - place.latitude) < 0.00001 && abs(it.longitude - place.longitude) < 0.00001 }
            Card(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(10.dp).fillMaxWidth(), shape = RoundedCornerShape(24.dp)) {
                Column(Modifier.padding(18.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(place.name, style = MaterialTheme.typography.titleLarge, maxLines = 2, modifier = Modifier.weight(1f))
                        IconButton(onClick = { selected = null }) { Icon(Icons.Filled.Close, "Close") }
                    }
                    if (place.subtitle.isNotEmpty()) Text(place.subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    Text("%.5f, %.5f".format(java.util.Locale.ROOT, place.latitude, place.longitude), style = MaterialTheme.typography.bodySmall)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(top = 8.dp)) {
                        FilledTonalButton(onClick = {
                            saved = if (isSaved) saved.filterNot { abs(it.latitude - place.latitude) < 0.00001 && abs(it.longitude - place.longitude) < 0.00001 }
                            else saved + place
                            store.saved = saved
                        }) { Text(if (isSaved) "Saved" else "Save") }
                        Button(onClick = {
                            val link = "https://www.openstreetmap.org/?mlat=${place.latitude}&mlon=${place.longitude}#map=16/${place.latitude}/${place.longitude}"
                            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "${place.name}\n$link"), "Share"))
                        }) { Text("Share") }
                    }
                }
            }
        }

        picture?.let { first -> StreetViewer(first) { picture = null } }

        if (page != Page.Map) {
            BackHandler { page = Page.Map }
            Surface(Modifier.fillMaxSize()) {
                if (page == Page.Settings) {
                    SettingsPage(
                        useLibre, placeNames, photo, esri, credits,
                        onMap = { useLibre = it; store.useMapLibre = it },
                        onNames = { placeNames = it; store.placeNames = it },
                        open = { flyTo(it) }, close = { page = Page.Map },
                    )
                } else {
                    SavedPage(saved, open = { flyTo(it) }, remove = { gone -> saved = saved - gone; store.saved = saved }, close = { page = Page.Map })
                }
            }
        }
    }
}

@Composable
private fun SearchPill(
    esri: List<MeshModel>, near: CameraState, onPlace: (Place) -> Unit, onWhole: () -> Unit, onSurprise: () -> Unit, onSaved: () -> Unit, onSettings: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    var places by remember { mutableStateOf(listOf<Place>()) }
    var menu by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    val models = remember(query, esri) {
        if (query.trim().length < 3) emptyList() else esri.asSequence().filter { it.title.contains(query.trim(), ignoreCase = true) }.take(6).map { it.place }.toList()
    }
    fun choose(p: Place) {
        query = ""
        places = emptyList()
        focus.clearFocus()
        onPlace(p)
    }
    Surface(shape = RoundedCornerShape(28.dp), tonalElevation = 3.dp, shadowElevation = 6.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.Menu, "Menu") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    listOf(
                        Triple("Whole Earth", Icons.Filled.Public, onWhole), Triple("Surprise me", Icons.Filled.Casino, onSurprise),
                        Triple("Saved places", Icons.Filled.Bookmarks, onSaved), Triple("Settings", Icons.Filled.Settings, onSettings),
                    ).forEach { (label, icon, action) ->
                        DropdownMenuItem(text = { Text(label) }, leadingIcon = { Icon(icon, null) }, onClick = { menu = false; focus.clearFocus(); action() })
                    }
                }
            }
            TextField(
                value = query, onValueChange = { query = it; if (it.isEmpty()) places = emptyList() },
                placeholder = { Text("Search places and 3D models") }, singleLine = true, modifier = Modifier.weight(1f),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedContainerColor = androidx.compose.ui.graphics.Color.Transparent,
                    focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent, unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { scope.launch { places = Data.search(query, near) } }),
            )
        }
    }
    if (places.isNotEmpty() || models.isNotEmpty()) {
        Card(Modifier.padding(top = 8.dp).heightIn(max = 340.dp)) {
            LazyColumn {
                items(places) { p ->
                    ListItem(headlineContent = { Text(p.name) }, supportingContent = { Text(p.subtitle, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                        leadingContent = { Icon(Icons.Filled.Place, null) }, modifier = Modifier.clickable { choose(p) })
                }
                items(models) { p ->
                    ListItem(headlineContent = { Text(p.name, maxLines = 1) }, supportingContent = { Text(p.subtitle, maxLines = 1) },
                        leadingContent = { Icon(Icons.Filled.ViewInAr, "3D model") },modifier = Modifier.clickable { choose(p) })
                }
            }
        }
    }
}
