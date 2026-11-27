// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
private fun Header(title: String, back: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(8.dp)) {
        IconButton(onClick = back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
        Text(title, style = MaterialTheme.typography.titleLarge)
    }
}

@Composable
private fun Title(text: String) = Text(text, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelLarge,
    modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp))

@Composable
fun SettingsPage(
    useLibre: Boolean, placeNames: Boolean, photo: List<MeshModel>, esri: List<MeshModel>, onScreen: List<String>,
    onMap: (Boolean) -> Unit, onNames: (Boolean) -> Unit, open: (Place) -> Unit, close: () -> Unit,
) {
    var list by remember { mutableStateOf<Pair<String, List<MeshModel>>?>(null) }
    val chosen = list
    if (chosen != null) {
        ModelList(chosen.first, chosen.second, open) { list = null }
        return
    }
    Column(Modifier.statusBarsPadding().navigationBarsPadding()) {
        Header("Settings", close)
        LazyColumn {
            item { Title("Map") }
            item {
                ListItem(headlineContent = { Text("ArcGIS") }, supportingContent = { Text("3D globe with the models of the Atlas") },
                    leadingContent = { RadioButton(!useLibre, onClick = { onMap(false) }) }, modifier = Modifier.clickable { onMap(false) })
            }
            item {
                ListItem(headlineContent = { Text("MapLibre") }, supportingContent = { Text("Open source map with streets and 3D buildings") },
                    leadingContent = { RadioButton(useLibre, onClick = { onMap(true) }) }, modifier = Modifier.clickable { onMap(true) })
            }
            if (!useLibre) item { ListItem(headlineContent = { Text("Place names") }, trailingContent = { Switch(placeNames, onCheckedChange = onNames) }) }
            item { Title("3D models in the Atlas") }
            items(listOf("Photo meshes" to photo, "Esri scene layers" to esri)) { entry ->
                ListItem(headlineContent = { Text(entry.first) }, trailingContent = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("${entry.second.size}")
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null)
                    }
                },
                    modifier = Modifier.clickable(enabled = entry.second.isNotEmpty()) { list = entry })
            }
            if (onScreen.isNotEmpty()) {
                item { Title("On the screen") }
                items(onScreen) { ListItem(headlineContent = { Text(it, style = MaterialTheme.typography.bodySmall) }) }
            }
            item { Title("This app") }
            item { UpdateSetting() }
            item { Title("Licences and credits") }
            items(listOf(
                "This app: MPL-2.0. Source: github.com/Luishae07/FEGlobe",
                "ArcGIS Maps SDK for Kotlin: Esri's own licence (not open source). MapLibre Native: BSD.",
                "Satellite: Powered by Esri. Esri, Maxar, Earthstar Geographics, and the GIS User Community. The pictures come through flowsearch.org, so Esri does not see your address.",
                "Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016 & 2017), CC BY 4.0",
                "Where Esri's picture does not come, close up: aerial photos of the government services named on the screen; German ones come through mesh.flowsearch.org, which keeps copies. Names: NASA GIBS. Terrain: Esri World Elevation.",
                "Place search: Nominatim, data © OpenStreetMap contributors (ODbL). App icon: Natural Earth (public domain).",
                "Street photos: Panoramax (panoramax.fr); each photo names its author and licence.",
                "The 3D models belong to their owners, named on the screen: mesh.flowsearch.org",
            )) { ListItem(headlineContent = { Text(it, style = MaterialTheme.typography.bodySmall) }) }
        }
    }
}

@Composable
private fun ModelList(title: String, models: List<MeshModel>, open: (Place) -> Unit, back: () -> Unit) {
    var query by remember { mutableStateOf("") }
    val found = remember(query, models) {
        if (query.isBlank()) models else models.filter { it.title.contains(query.trim(), true) || it.owner.contains(query.trim(), true) }
    }
    androidx.activity.compose.BackHandler { back() }
    Column(Modifier.statusBarsPadding().navigationBarsPadding()) {
        Header(title, back)
        OutlinedTextField(query, { query = it }, placeholder = { Text("Name or owner") }, singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
        LazyColumn {
            items(found) { m ->
                ListItem(headlineContent = { Text(m.title, maxLines = 2) }, supportingContent = { Text(m.owner, maxLines = 1) },
                    modifier = Modifier.clickable { open(m.place) })
            }
        }
    }
}

@Composable
fun SavedPage(saved: List<Place>, open: (Place) -> Unit, remove: (Place) -> Unit, close: () -> Unit) {
    Column(Modifier.statusBarsPadding().navigationBarsPadding()) {
        Header("Saved places", close)
        if (saved.isEmpty()) Text("Search a place and press Save.", Modifier.padding(16.dp))
        LazyColumn {
            items(saved) { p ->
                ListItem(headlineContent = { Text(p.name) }, supportingContent = { Text("%.4f, %.4f".format(p.latitude, p.longitude)) },
                    trailingContent = { IconButton(onClick = { remove(p) }) { Icon(Icons.Filled.Close, "Remove") } }, modifier = Modifier.clickable { open(p) })
            }
        }
    }
}
