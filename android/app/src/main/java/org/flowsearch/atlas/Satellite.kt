// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import com.arcgismaps.arcgisservices.LevelOfDetail
import com.arcgismaps.geometry.Envelope
import com.arcgismaps.geometry.Point
import com.arcgismaps.geometry.SpatialReference
import com.arcgismaps.mapping.layers.CustomTiledLayer
import com.arcgismaps.mapping.layers.TileImageFormat
import com.arcgismaps.mapping.layers.TileInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.math.PI
import kotlin.math.atan
import kotlin.math.sinh

/**
 * Esri World Imagery through the Flowsearch server, which holds the account's key. Every request carries the time and its
 * HMAC-SHA256, keyed with a number put in when the app is built (not part of the source code).
 * Only where Esri's picture does not come, the official aerial photo of the place is asked for instead.
 */
object Satellite {
    private const val ADDRESS = "https://flowsearch.org/api/app-map"
    private const val EDGE = 20037508.342789244

    // the German states, whose slow map services are not asked directly: mesh.flowsearch.org keeps their tiles on its disk
    private val kept = setOf("berlin2024", "saarland-nrw", "brandenburg", "saxony", "thuringia", "saxony-anhalt", "hesse",
        "rhineland", "bavaria", "lower-saxony", "mecklenburg")

    private fun picture(address: String, timeout: Int, prepare: HttpURLConnection.() -> Unit = {}): ByteArray {
        val connection = URL(address).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = timeout
            connection.readTimeout = timeout
            connection.prepare()
            if (connection.responseCode != 200 || connection.contentType?.startsWith("image/") != true) {
                throw IOException("picture ${connection.responseCode}")
            }
            return connection.inputStream.use { it.readBytes() }
        } finally {
            connection.disconnect()
        }
    }

    private fun esri(level: Int, row: Int, column: Int): ByteArray {
        if (BuildConfig.ATLAS_TILE_NUMBER.isEmpty()) throw IOException("built without the number")
        val time = (System.currentTimeMillis() / 1000).toString()
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(BuildConfig.ATLAS_TILE_NUMBER.toByteArray(), "HmacSHA256")) }
        val sign = mac.doFinal(time.toByteArray()).joinToString("") { "%02x".format(it) }
        return picture("$ADDRESS?z=$level&y=$row&x=$column", 12_000) {
            requestMethod = "POST"
            setRequestProperty("X-Atlas-Time", time)
            setRequestProperty("X-Atlas-Sign", sign)
        }
    }

    /** the address of one square of the grid at a source: a tiled service, or a map service (WMS) */
    private fun address(source: AerialSource, level: Int, row: Int, column: Int): String {
        val template = when {
            source.id in kept -> "https://mesh.flowsearch.org/dop/${source.id}/{z}/{x}/{y}.png"
            // USGS: the same photos as a tiled service
            source.template.contains("exportImage") -> "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}"
            else -> source.template
        }
        val size = 2 * EDGE / (1 shl level)
        val box = listOf(column * size - EDGE, EDGE - (row + 1) * size, (column + 1) * size - EDGE, EDGE - row * size)
        return template.replace("{z}", "$level").replace("{x}", "$column").replace("{y}", "$row")
            .replace("{bbox}", box.joinToString(",") { String.format(Locale.US, "%.6f", it) })
    }

    /** the official aerial photo of the same square, from the first source that covers it and answers (close levels only) */
    private fun official(sources: List<AerialSource>, level: Int, row: Int, column: Int): ByteArray {
        val count = (1 shl level).toDouble()
        val longitude = (column + 0.5) / count * 360 - 180
        val latitude = atan(sinh(PI * (1 - 2 * (row + 0.5) / count))) * 180 / PI
        if (level >= 11) {
            for (source in sources.filter { it.covers(latitude, longitude) }) {
                runCatching { return picture(address(source, level, row, column), 25_000) }
            }
        }
        throw IOException("no picture") // the Sentinel-2 picture below is seen
    }

    fun layer(sources: List<AerialSource>): CustomTiledLayer {
        val levels = (0..18).map { LevelOfDetail(it, 156543.03392804097 / (1 shl it), 591657527.591555 / (1 shl it)) }
        val mercator = SpatialReference.webMercator()
        val info = TileInfo(96, TileImageFormat.Mixed, levels, Point(-EDGE, EDGE, mercator), mercator, 256, 256)
        return CustomTiledLayer(info, Envelope(-EDGE, -EDGE, EDGE, EDGE, spatialReference = mercator)) { key ->
            withContext(Dispatchers.IO) {
                try {
                    esri(key.level, key.row, key.column)
                } catch (e: IOException) {
                    ensureActive()
                    official(sources, key.level, key.row, key.column)
                }
            }
        }.apply { attribution = "Powered by Esri. Esri, Maxar, Earthstar Geographics, and the GIS User Community" }
    }
}
