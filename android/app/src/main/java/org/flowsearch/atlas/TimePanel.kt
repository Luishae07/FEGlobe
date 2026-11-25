// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt

/** What is loaded about the past around the place looked at. */
class Past(val shown: List<OldBuilding>, val status: String)

/** the buildings of a year around the camera; they are loaded again only after a real move */
@Composable
fun rememberPast(year: Int?, camera: CameraState): Past {
    var loaded by remember { mutableStateOf(listOf<OldBuilding>()) }
    var middle by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    var loading by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val near = camera.distance < History.NEAR
    LaunchedEffect(year != null, camera.latitude, camera.longitude, near) {
        if (year == null || !near) return@LaunchedEffect
        val m = middle
        val moved = m == null || abs(m.first - camera.latitude) * 110_574 > 350 ||
            abs(m.second - camera.longitude) * 111_320 * cos(Math.toRadians(camera.latitude)) > 350
        if (!moved) return@LaunchedEffect
        delay(500)
        loading = true
        failed = false
        try {
            loaded = History.buildings(camera.latitude, camera.longitude, 900.0)
            middle = camera.latitude to camera.longitude
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            failed = true
        } finally {
            loading = false
        }
    }
    val shown = remember(year, loaded, near) { if (year == null || !near) emptyList() else loaded.filter { it.standsIn(year) } }
    val status = when {
        !near -> "Zoom in to a few streets to see buildings."
        loading -> "Loading buildings…"
        failed -> "The buildings could not be loaded. Move the map to try again."
        shown.isEmpty() -> "No buildings of this year are mapped here."
        else -> "${shown.size} buildings, ${shown.count { !it.measured }} with a guessed height (grey)."
    }
    return Past(shown, status)
}

@Composable
fun TimePanel(year: Int, camera: CameraState, status: String, onYear: (Int) -> Unit, onClose: () -> Unit, modifier: Modifier = Modifier) {
    var slider by remember { mutableFloatStateOf(year.toFloat()) }
    LaunchedEffect(year) { slider = year.toFloat() }
    val picture = History.picture(camera.latitude, camera.longitude, year)
    Card(modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { if (year > History.FIRST_YEAR) onYear(year - 1) }) { Text("−", style = MaterialTheme.typography.headlineSmall) }
                Text("${slider.roundToInt()}", style = MaterialTheme.typography.headlineMedium)
                TextButton(onClick = { if (year < History.lastYear) onYear(year + 1) }) { Text("+", style = MaterialTheme.typography.headlineSmall) }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onClose) { Text("Today") }
            }
            // the maps change when the finger lets go
            Slider(slider, onValueChange = { slider = it }, onValueChangeFinished = { onYear(slider.roundToInt()) },
                valueRange = History.FIRST_YEAR.toFloat()..History.lastYear.toFloat())
            Text(status, style = MaterialTheme.typography.bodySmall)
            Text(picture?.label ?: "No old picture for this year here: the ground shows today.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
