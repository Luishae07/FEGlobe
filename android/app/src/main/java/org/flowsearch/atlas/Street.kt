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
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.ln
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

/** Where there are photos: streets when near; from far away dots, one for each area that has some. */
class Coverage(val lines: List<StreetLine> = emptyList(), val dots: List<Pair<Double, Double>> = emptyList()) {
    val isEmpty get() = lines.isEmpty() && dots.isEmpty()
}

/** The coverage tiles wanted for a camera: their zoom level and the middle one. */
data class TileView(val zoom: Int, val x: Int, val y: Int)

object Panoramax {
    const val API = "https://api.panoramax.xyz/api"
    /** coverage tiles for maps that read vector tiles themselves */
    const val TILES = "$API/map/{z}/{x}/{y}.mvt"
    /** the blue of the covered streets */
    const val BLUE = "#1a73ff"
    /** the camera must be this near, in metres, for a tap to open a photo; from farther away it flies closer */
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

    /** below this tile level the tiles hold areas (a grid), from it on streets */
    private const val STREETS_FROM = 7

    /** tiles already read: moving back and forth asks nothing twice */
    private val cache = object : LinkedHashMap<String, Coverage>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Coverage>) = size > 200
    }

    fun view(latitude: Double, longitude: Double, distance: Double): TileView {
        val zoom = (ln(40_000_000.0 * max(0.1, cos(Math.toRadians(latitude))) / max(100.0, distance)) / ln(2.0) + 1).toInt().coerceIn(2, 14)
        val size = 1 shl zoom
        val x = floor((longitude + 180) / 360 * size).toInt()
        val y = floor((1 - asinh(tan(Math.toRadians(latitude.coerceIn(-85.0, 85.0)))) / PI) / 2 * size).toInt()
        return if (size <= 4) TileView(zoom, 0, 0) else TileView(zoom, x, y) // far out: the whole world
    }

    /** where there are photos around the middle of the view; all tiles are asked at the same time */
    suspend fun coverage(view: TileView): Coverage = coroutineScope {
        val size = 1 shl view.zoom
        val wanted = if (size <= 4) (0 until size).flatMap { x -> (0 until size).map { y -> x to y } }
        else (-2..2).flatMap { dx -> (-2..2).map { dy -> Math.floorMod(view.x + dx, size) to (view.y + dy) } }.filter { it.second in 0 until size }
        val parts = wanted.map { (tx, ty) ->
            async(Dispatchers.IO) {
                val key = "${view.zoom}/$tx/$ty"
                synchronized(cache) { cache[key] } ?: runCatching { read(download("$API/map/$key.mvt"), view.zoom, tx, ty) }
                    .getOrNull()?.also { synchronized(cache) { cache[key] = it } } ?: Coverage()
            }
        }.awaitAll()
        Coverage(parts.flatMap { it.lines }, parts.flatMap { it.dots })
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

    /** is this value of a tile a number above zero? */
    private fun positive(value: Reader): Boolean {
        while (value.more()) {
            val k = value.number().toInt()
            when {
                k shr 3 == 4 || k shr 3 == 5 -> return value.number() > 0
                k shr 3 == 6 -> return value.number().let { (it ushr 1) xor -(it and 1) } > 0
                k shr 3 == 2 -> return ByteBuffer.wrap(value.b, value.at, 4).order(ByteOrder.LITTLE_ENDIAN).float > 0
                k shr 3 == 3 -> return ByteBuffer.wrap(value.b, value.at, 8).order(ByteOrder.LITTLE_ENDIAN).double > 0
                else -> value.skip(k and 7)
            }
        }
        return false
    }

    private fun read(data: ByteArray, zoom: Int, tileX: Int, tileY: Int): Coverage {
        val result = mutableListOf<StreetLine>()
        val dots = mutableListOf<Pair<Double, Double>>()
        val wantedLayer = if (zoom < STREETS_FROM) "grid" else "sequences"
        val size = (1 shl zoom).toDouble()
        val tile = Reader(data)
        while (tile.more()) {
            val key = tile.number().toInt()
            if (key shr 3 != 3) { tile.skip(key and 7); continue }
            val layer = tile.part()
            var name = ""
            var extent = 4096
            val features = mutableListOf<Reader>()
            val keys = mutableListOf<String>()
            val values = mutableListOf<Reader>()
            while (layer.more()) {
                val k = layer.number().toInt()
                when (k shr 3) {
                    1 -> layer.part().let { name = String(it.b, it.at, it.end - it.at) }
                    2 -> features.add(layer.part())
                    3 -> layer.part().let { keys.add(String(it.b, it.at, it.end - it.at)) }
                    4 -> values.add(layer.part())
                    5 -> extent = layer.number().toInt()
                    else -> layer.skip(k and 7)
                }
            }
            if (name != wantedLayer) continue
            // an area of the grid counts only if its "coef" says that it has photos
            val coef = keys.indexOf("coef")
            val full = values.map { positive(Reader(it.b, it.at, it.end)) }
            for (feature in features) {
                var empty = false
                while (feature.more()) {
                    val k = feature.number().toInt()
                    if (k shr 3 == 2) {
                        val tags = feature.part()
                        while (tags.more()) {
                            val key = tags.number().toInt()
                            val value = tags.number().toInt()
                            if (key == coef && value in full.indices && !full[value]) empty = true
                        }
                        continue
                    }
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
                                if (wantedLayer == "sequences" && line.size > 1) result.add(line)
                                line = mutableListOf()
                            }
                            val longitude = (tileX + x.toDouble() / extent) / size * 360 - 180
                            val latitude = Math.toDegrees(atan(sinh(PI * (1 - 2 * (tileY + y.toDouble() / extent) / size))))
                            // points over the edge of the tile belong to the neighbour
                            if (wantedLayer == "grid" && !empty && x in 0 until extent && y in 0 until extent) dots.add(longitude to latitude)
                            line.add(longitude to latitude)
                        }
                    }
                    if (wantedLayer == "sequences" && line.size > 1) result.add(line)
                }
            }
        }
        return Coverage(result, dots)
    }
}
