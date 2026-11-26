// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.PI
import kotlin.math.asinh
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.sinh
import kotlin.math.tan

/** One street photo of Panoramax. */
data class StreetPicture(
    val address: String, val latitude: Double, val longitude: Double, val image: String, val full: Boolean,
    val author: String, val date: String, val licence: String, val previous: String?, val next: String?,
)

/** A stretch of street that has photos: pairs of longitude and latitude. */
typealias StreetLine = List<Pair<Double, Double>>

object Panoramax {
    const val API = "https://api.panoramax.xyz/api"
    /** coverage tiles for maps that read vector tiles themselves */
    const val TILES = "$API/map/{z}/{x}/{y}.mvt"
    /** the blue of the covered streets */
    const val BLUE = "#1a73ff"
    /** the camera must be this near, in metres, for the streets to be shown */
    const val NEAR = 4_000.0

    private fun download(address: String): ByteArray {
        val c = URL(address).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 30_000
        c.setRequestProperty("User-Agent", "Atlas-Android")
        try {
            return c.inputStream.use { it.readBytes() }
        } finally {
            c.disconnect()
        }
    }

    suspend fun bytes(address: String): ByteArray = withContext(Dispatchers.IO) { download(address) }

    private fun picture(item: JSONObject): StreetPicture? {
        val properties = item.getJSONObject("properties")
        val at = item.getJSONObject("geometry").getJSONArray("coordinates")
        val assets = item.getJSONObject("assets")
        val image = assets.optJSONObject("sd")?.optString("href") ?: assets.optJSONObject("hd")?.optString("href") ?: return null
        val links = item.getJSONArray("links")
        var self: String? = null
        var previous: String? = null
        var next: String? = null
        for (i in 0 until links.length()) {
            val link = links.getJSONObject(i)
            val href = link.optString("href").let { if (it.startsWith("/")) "https://api.panoramax.xyz$it" else it }
            when (link.optString("rel")) {
                "self" -> self = href
                "prev" -> previous = href
                "next" -> next = href
            }
        }
        val view = properties.optJSONObject("pers:interior_orientation")?.optDouble("field_of_view", 0.0) ?: 0.0
        return StreetPicture(
            self ?: return null, at.getDouble(1), at.getDouble(0), image, view >= 360,
            properties.optString("geovisio:producer", "Panoramax contributor"), properties.optString("datetime").take(10),
            properties.optString("license"), previous, next,
        )
    }

    suspend fun load(address: String): StreetPicture? = withContext(Dispatchers.IO) { picture(JSONObject(String(download(address)))) }

    /** the photo nearest to a tapped place (a full round one wins when it is about as near), or null */
    suspend fun nearest(latitude: Double, longitude: Double, reach: Double): StreetPicture? = withContext(Dispatchers.IO) {
        val dLat = reach / 110_574
        val dLon = reach / (111_320 * max(0.1, cos(Math.toRadians(latitude))))
        val answer = JSONObject(String(download("$API/search?limit=100&bbox=${longitude - dLon},${latitude - dLat},${longitude + dLon},${latitude + dLat}")))
        val found = answer.getJSONArray("features")
        (0 until found.length()).mapNotNull { runCatching { picture(found.getJSONObject(it)) }.getOrNull() }.minByOrNull {
            val y = (it.latitude - latitude) * 110_574
            val x = (it.longitude - longitude) * 111_320 * cos(Math.toRadians(latitude))
            kotlin.math.hypot(x, y) * (if (it.full) 0.6 else 1.0)
        }
    }

    // ---- the covered streets, read from the vector tiles (Mapbox Vector Tile format) ----

    private const val ZOOM = 14

    /** the streets with photos around a place */
    suspend fun streets(latitude: Double, longitude: Double): List<StreetLine> = coroutineScope {
        val size = 1 shl ZOOM
        val x = floor((longitude + 180) / 360 * size).toInt()
        val y = floor((1 - asinh(tan(Math.toRadians(latitude))) / PI) / 2 * size).toInt()
        (-1..1).flatMap { dx -> (-1..1).map { dy -> (x + dx) to (y + dy) } }.map { (tx, ty) ->
            async(Dispatchers.IO) { runCatching { lines(download("$API/map/$ZOOM/$tx/$ty.mvt"), tx, ty) }.getOrDefault(emptyList()) }
        }.awaitAll().flatten()
    }

    private class Reader(val b: ByteArray, var at: Int = 0, val end: Int = b.size) {
        fun more() = at < end
        fun number(): Long {
            var result = 0L
            var shift = 0
            while (true) {
                val c = b[at++].toInt()
                result = result or ((c and 127).toLong() shl shift)
                if (c >= 0) return result
                shift += 7
            }
        }
        /** a part with its length in front */
        fun part(): Reader {
            val length = number().toInt()
            val r = Reader(b, at, at + length)
            at += length
            return r
        }
        fun skip(kind: Int) {
            when (kind) {
                0 -> number()
                1 -> at += 8
                2 -> part()
                else -> at += 4
            }
        }
    }

    private fun lines(data: ByteArray, tileX: Int, tileY: Int): List<StreetLine> {
        val result = mutableListOf<StreetLine>()
        val tile = Reader(data)
        while (tile.more()) {
            val key = tile.number().toInt()
            if (key shr 3 != 3) { tile.skip(key and 7); continue }
            val layer = tile.part()
            var name = ""
            var extent = 4096
            val features = mutableListOf<Reader>()
            while (layer.more()) {
                val k = layer.number().toInt()
                when (k shr 3) {
                    1 -> layer.part().let { name = String(it.b, it.at, it.end - it.at) }
                    2 -> features.add(layer.part())
                    5 -> extent = layer.number().toInt()
                    else -> layer.skip(k and 7)
                }
            }
            if (name != "sequences") continue
            for (feature in features) {
                while (feature.more()) {
                    val k = feature.number().toInt()
                    if (k shr 3 != 4) { feature.skip(k and 7); continue }
                    // the geometry: "move to" starts a line, "line to" goes on; steps are relative
                    val g = feature.part()
                    var x = 0
                    var y = 0
                    var line = mutableListOf<Pair<Double, Double>>()
                    while (g.more()) {
                        val command = g.number().toInt()
                        val what = command and 7
                        if (what != 1 && what != 2) continue
                        repeat(command shr 3) {
                            val a = g.number().toInt()
                            val c = g.number().toInt()
                            x += (a ushr 1) xor -(a and 1)
                            y += (c ushr 1) xor -(c and 1)
                            if (what == 1) {
                                if (line.size > 1) result.add(line)
                                line = mutableListOf()
                            }
                            val size = (1 shl ZOOM).toDouble()
                            val longitude = (tileX + x.toDouble() / extent) / size * 360 - 180
                            val latitude = Math.toDegrees(atan(sinh(PI * (1 - 2 * (tileY + y.toDouble() / extent) / size))))
                            line.add(longitude to latitude)
                        }
                    }
                    if (line.size > 1) result.add(line)
                }
            }
        }
        return result
    }
}
