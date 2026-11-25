// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min

/** A place to fly to; distance: how far the camera stands, in metres. */
data class Place(val name: String, val subtitle: String, val latitude: Double, val longitude: Double, val distance: Double = 1200.0)

/** Where the camera of the map is. */
data class CameraState(val latitude: Double = 30.0, val longitude: Double = 10.0, val distance: Double = 18_000_000.0, val heading: Double = 0.0)

/** "Fly there": the maps watch it; every request has its own number. */
data class FlyRequest(val number: Long, val latitude: Double, val longitude: Double, val distance: Double, val heading: Double, val tilted: Boolean)

/** One 3D model of the Mesh Atlas: an Esri scene layer, or a 3D Tiles photo mesh. */
data class MeshModel(
    val title: String, val owner: String, val url: String, val tiles3d: Boolean,
    val west: Double, val south: Double, val east: Double, val north: Double, val views: Double,
) {
    fun covers(latitude: Double, longitude: Double) = longitude in west..east && latitude in south..north
    val place: Place
        get() {
            val width = max(300.0, (east - west) * 111_320 * cos(Math.toRadians((north + south) / 2)))
            return Place(title, owner, (north + south) / 2, (east + west) / 2, min(6000.0, width * 0.8))
        }
}

/** One open source of aerial photos (assets/aerial.json). */
data class AerialSource(val id: String, val credit: String, val template: String, val west: Double, val south: Double, val east: Double, val north: Double) {
    fun covers(latitude: Double, longitude: Double) = longitude in west..east && latitude in south..north
}

object Data {
    private const val ATLAS = "https://mesh.flowsearch.org/"

    private fun download(address: String): String {
        val c = URL(address).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 40_000
        c.setRequestProperty("User-Agent", "Atlas-Android")
        try {
            return c.inputStream.bufferedReader().use { it.readText() }
        } finally {
            c.disconnect()
        }
    }

    /** the list of models in a file of the Atlas; broken entries are skipped */
    suspend fun models(file: String): List<MeshModel> = withContext(Dispatchers.IO) {
        val list = JSONArray(download(ATLAS + file))
        (0 until list.length()).mapNotNull { i ->
            runCatching {
                val o = list.getJSONObject(i)
                val e = o.getJSONArray("e")
                MeshModel(
                    o.optString("t"), o.optString("o"), o.getString("u"), o.optString("type") == "3dt",
                    e.getJSONArray(0).getDouble(0), e.getJSONArray(0).getDouble(1), e.getJSONArray(1).getDouble(0), e.getJSONArray(1).getDouble(1),
                    o.optDouble("v", 0.0),
                )
            }.getOrNull()
        }.sortedByDescending { it.views }
    }

    /** places by name: Photon, made from OpenStreetMap (no key) */
    suspend fun search(query: String): List<Place> = withContext(Dispatchers.IO) {
        runCatching {
            val answer = JSONObject(download("https://photon.komoot.io/api/?limit=5&q=" + URLEncoder.encode(query, "UTF-8")))
            val features = answer.getJSONArray("features")
            (0 until features.length()).map { i ->
                val f = features.getJSONObject(i)
                val p = f.getJSONObject("properties")
                val at = f.getJSONObject("geometry").getJSONArray("coordinates")
                val where = listOf(p.optString("city"), p.optString("country")).filter { it.isNotEmpty() }.joinToString(", ")
                Place(p.optString("name", query), where, at.getDouble(1), at.getDouble(0))
            }
        }.getOrDefault(emptyList())
    }

    fun aerial(context: Context): List<AerialSource> = runCatching {
        val list = JSONArray(context.assets.open("aerial.json").bufferedReader().use { it.readText() })
        (0 until list.length()).map { i ->
            val o = list.getJSONObject(i)
            val b = o.getJSONArray("box")
            AerialSource(o.getString("id"), o.getString("credit"), o.getString("template"), b.getDouble(0), b.getDouble(1), b.getDouble(2), b.getDouble(3))
        }
    }.getOrDefault(emptyList())
}

/** What is kept on the phone: the saved places and the settings. */
class Store(context: Context) {
    private val prefs = context.getSharedPreferences("atlas", Context.MODE_PRIVATE)

    var useMapLibre: Boolean
        get() = prefs.getBoolean("maplibre", false)
        set(v) = prefs.edit().putBoolean("maplibre", v).apply()
    var placeNames: Boolean
        get() = prefs.getBoolean("names", true)
        set(v) = prefs.edit().putBoolean("names", v).apply()

    var saved: List<Place>
        get() = runCatching {
            val list = JSONArray(prefs.getString("saved", "[]"))
            (0 until list.length()).map { i ->
                val o = list.getJSONObject(i)
                Place(o.getString("n"), "Saved place", o.getDouble("a"), o.getDouble("o"), o.getDouble("d"))
            }
        }.getOrDefault(emptyList())
        set(v) {
            val list = JSONArray()
            v.forEach { list.put(JSONObject().put("n", it.name).put("a", it.latitude).put("o", it.longitude).put("d", it.distance)) }
            prefs.edit().putString("saved", list.toString()).apply()
        }
}
