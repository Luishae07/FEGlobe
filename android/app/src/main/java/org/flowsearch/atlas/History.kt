// SPDX-License-Identifier: MPL-2.0
package org.flowsearch.atlas

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlin.math.cos
import kotlin.math.max

/** A building of the past (OpenHistoricalMap). ring: pairs of longitude and latitude. */
data class OldBuilding(val ring: List<Pair<Double, Double>>, val from: Int?, val to: Int?, val height: Double, val measured: Boolean) {
    /** a building counts for the year it was built and for the year it disappeared */
    fun standsIn(year: Int) = (from == null || from <= year) && (to == null || to >= year)
}

/** Photos of the past. template: tiles with {z} {x} {y}; or a map service (WMS) with its layer. */
data class OldPicture(val id: String, val label: String, val credit: String, val template: String, val maxLevel: Int = 18, val wmsLayer: String? = null)

object History {
    const val FIRST_YEAR = 1850
    val lastYear: Int = java.util.Calendar.getInstance().get(java.util.Calendar.YEAR)
    /** the camera must be this near, in metres, for buildings to be loaded */
    const val NEAR = 5_000.0

    /** the photos for a place and a year, or null: then only today's picture exists */
    fun picture(latitude: Double, longitude: Double, year: Int): OldPicture? {
        fun inside(west: Double, south: Double, east: Double, north: Double) = longitude in west..east && latitude in south..north
        if (year in 1945..1965 && inside(13.08, 52.33, 13.77, 52.68)) {
            return OldPicture("berlin1953", "Aerial photos of Berlin, 1953", "Geoportal Berlin, Luftbilder 1953 (dl-de/zero-2-0)",
                "https://gdi.berlin.de/services/wms/luftbild_1953_22", wmsLayer = "c_luftbilder_1953_22_raster")
        }
        if (year >= 1946 && year < lastYear && inside(5.9, 45.8, 10.5, 47.8)) {
            return OldPicture("swiss$year", "Aerial photos of Switzerland, $year (where flown)", "swisstopo, SWISSIMAGE time travel",
                "https://wmts.geo.admin.ch/1.0.0/ch.swisstopo.swissimage-product/default/$year/3857/{z}/{x}/{y}.jpeg")
        }
        if (year in 1950..1964 && inside(-9.4, 36.0, 3.2, 42.4)) {
            return OldPicture("spain1956", "Aerial photos of Spain, 1956–57", "© Instituto Geográfico Nacional de España (CC BY 4.0)",
                "https://www.ign.es/wms/pnoa-historico", wmsLayer = "AMS_1956-1957")
        }
        if (year in 1945..1968 && inside(-5.2, 42.3, 8.3, 51.1)) {
            return OldPicture("france1950", "Aerial photos of France, 1950–65", "IGN France (Licence Ouverte)",
                "https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=ORTHOIMAGERY.ORTHOPHOTOS.1950-1965&STYLE=normal&TILEMATRIXSET=PM&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&FORMAT=image/png")
        }
        // the whole world from space: the yearly Landsat pictures of NASA, 30 m to a point
        val landsat = listOf(1985, 1990, 2000).minByOrNull { kotlin.math.abs(it - year) }!!
        if (kotlin.math.abs(landsat - year) <= 2) {
            return OldPicture("landsat$landsat", "Landsat satellite picture, about $landsat", "NASA GIBS, Landsat WELD",
                "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/Landsat_WELD_CorrectedReflectance_TrueColor_Global_Annual/default/${landsat - 1}-12-01/GoogleMapsCompatible_Level12/{z}/{y}/{x}.jpg", maxLevel = 12)
        }
        return null
    }

    private fun yearOf(date: String): Int? = Regex("^~?\\s*(\\d{3,4})").find(date.trim())?.groupValues?.get(1)?.toIntOrNull()
    private fun number(text: String): Double? = Regex("^\\s*(\\d+(\\.\\d+)?)\\s*(m)?\\s*$").find(text)?.groupValues?.get(1)?.toDoubleOrNull()

    /** all buildings of all times around a place; radius in metres */
    suspend fun buildings(latitude: Double, longitude: Double, radius: Double): List<OldBuilding> = withContext(Dispatchers.IO) {
        val dLat = radius / 110_574
        val dLon = radius / (111_320 * max(0.1, cos(Math.toRadians(latitude))))
        val box = "${latitude - dLat},${longitude - dLon},${latitude + dLat},${longitude + dLon}"
        val query = "[out:json][timeout:30];(way[\"building\"]($box);relation[\"building\"]($box););out geom 5000;"
        val c = URL("https://overpass-api.openhistoricalmap.org/api/interpreter").openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 45_000
        c.requestMethod = "POST"
        c.doOutput = true
        c.setRequestProperty("User-Agent", "Atlas-Android")
        val text = try {
            c.outputStream.use { it.write(("data=" + URLEncoder.encode(query, "UTF-8")).toByteArray()) }
            c.inputStream.bufferedReader().use { it.readText() }
        } finally {
            c.disconnect()
        }
        val elements = JSONObject(text).getJSONArray("elements")
        val result = mutableListOf<OldBuilding>()
        for (i in 0 until elements.length()) {
            val e = elements.getJSONObject(i)
            val tags = e.optJSONObject("tags") ?: continue
            // the outlines: of a way itself, or of the outer parts of a relation
            val outlines = if (e.has("geometry")) listOf(e.getJSONArray("geometry")) else {
                val members = e.optJSONArray("members") ?: continue
                (0 until members.length()).map { members.getJSONObject(it) }.filter { it.optString("role") == "outer" }.mapNotNull { it.optJSONArray("geometry") }
            }
            val stated = number(tags.optString("height"))
            val floors = number(tags.optString("building:levels"))
            for (outline in outlines) {
                val ring = (0 until outline.length()).mapNotNull { n -> outline.optJSONObject(n)?.let { it.getDouble("lon") to it.getDouble("lat") } }
                if (ring.size < 4 || ring.first() != ring.last()) continue
                result.add(OldBuilding(ring, yearOf(tags.optString("start_date")), yearOf(tags.optString("end_date")),
                    stated ?: floors?.let { it * 3 } ?: 9.0, stated != null || floors != null))
            }
        }
        result
    }
}
