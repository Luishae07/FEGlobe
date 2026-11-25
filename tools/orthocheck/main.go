// SPDX-License-Identifier: MPL-2.0
// Asks every candidate source of open aerial photos for one square near a town of its area, and writes the ones that answer with a real picture
// to the engine:  go run tools/orthocheck/main.go
package main

import (
	"encoding/json"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"math"
	"net/http"
	"os"
	"strings"
	"time"
)

type source struct {
	ID       string     `json:"id"`
	Credit   string     `json:"credit"`
	Template string     `json:"template"` // {bbox} (EPSG:3857) or {z} {x} {y}
	Box      [4]float64 `json:"box"`      // west, south, east, north
	MaxZoom  int        `json:"maxZoom"`
	test     [2]float64 // longitude, latitude
}

func wms(base, layer string) string {
	sep := "?"
	if strings.Contains(base, "?") {
		sep = "&"
	}
	return base + sep + "SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=" + layer + "&STYLES=&CRS=EPSG:3857&BBOX={bbox}&WIDTH=256&HEIGHT=256&FORMAT=image/png&TRANSPARENT=TRUE"
}

// the smaller areas first: the first source whose box holds a square is asked
var candidates = []source{
	{"berlin", "Geoportal Berlin (dl-de/zero-2.0)", wms("https://gdi.berlin.de/services/wms/truedop_2025", "truedop_2025"), [4]float64{13.09, 52.34, 13.76, 52.68}, 20, [2]float64{13.3777, 52.5163}},
	{"berlin2024", "Geoportal Berlin (dl-de/zero-2.0)", wms("https://gdi.berlin.de/services/wms/truedop_2024", "truedop_2024"), [4]float64{13.09, 52.34, 13.76, 52.68}, 20, [2]float64{13.3777, 52.5163}},
	{"hamburg", "FHH, LGV Hamburg (dl-de/by-2.0)", wms("https://geodienste.hamburg.de/HH_WMS_DOP", "DOP"), [4]float64{9.73, 53.39, 10.33, 53.74}, 20, [2]float64{9.99, 53.55}},
	{"luxembourg", "Administration du cadastre, Luxembourg", wms("https://wmts.geoportail.lu/opendata/service", "ortho_latest"), [4]float64{5.74, 49.45, 6.53, 50.18}, 19, [2]float64{6.13, 49.61}},
	{"switzerland", "swisstopo", wms("https://wms.geo.admin.ch/", "ch.swisstopo.swissimage"), [4]float64{5.96, 45.82, 10.49, 47.81}, 20, [2]float64{7.447, 46.948}},
	{"netherlands", "PDOK / Beeldmateriaal Nederland (CC BY 4.0)", wms("https://service.pdok.nl/hwh/luchtfotorgb/wms/v1_0", "Actueel_orthoHR"), [4]float64{3.36, 50.75, 7.23, 53.55}, 20, [2]float64{4.895, 52.370}},
	{"flanders", "Digitaal Vlaanderen", wms("https://geo.api.vlaanderen.be/omw/wms", "OMWRGB23VL"), [4]float64{2.54, 50.68, 5.92, 51.50}, 19, [2]float64{3.72, 51.05}},
	{"wallonia", "Service public de Wallonie", wms("https://geoservices.wallonie.be/arcgis/services/IMAGERIE/ORTHO_LAST/MapServer/WMSServer", "0"), [4]float64{2.85, 49.49, 6.41, 50.82}, 19, [2]float64{4.87, 50.46}},
	{"saarland-nrw", "Geobasis NRW (dl-de/zero-2.0)", wms("https://www.wms.nrw.de/geobasis/wms_nw_dop", "nw_dop_rgb"), [4]float64{5.87, 50.32, 9.46, 52.53}, 20, [2]float64{6.96, 50.94}},
	{"brandenburg", "GeoBasis-DE/LGB (dl-de/by-2.0)", wms("https://isk.geobasis-bb.de/mapproxy/dop20c/service/wms", "bebb_dop20c"), [4]float64{11.27, 51.36, 14.77, 53.56}, 20, [2]float64{13.06, 52.40}},
	{"saxony", "GeoSN, Sachsen (dl-de/by-2.0)", wms("https://geodienste.sachsen.de/wms_geosn_dop-rgb/guest", "sn_dop_020"), [4]float64{11.87, 50.17, 15.04, 51.69}, 20, [2]float64{13.737, 51.05}},
	{"thuringia", "GDI-Th (dl-de/by-2.0)", wms("https://www.geoproxy.geoportal-th.de/geoproxy/services/DOP", "th_dop"), [4]float64{9.87, 50.20, 12.65, 51.65}, 20, [2]float64{11.03, 50.98}},
	{"saxony-anhalt", "GeoBasis-DE/LVermGeo ST (dl-de/by-2.0)", wms("https://www.geodatenportal.sachsen-anhalt.de/wss/service/ST_LVermGeo_DOP_WMS_OpenData/guest", "lsa_lvermgeo_dop20_2"), [4]float64{10.56, 50.94, 13.19, 53.04}, 20, [2]float64{11.63, 52.13}},
	{"hesse", "HVBG Hessen (dl-de/zero-2.0)", wms("https://www.gds-srv.hessen.de/cgi-bin/lika-services/ogc-free-images.ows", "he_dop20_rgb"), [4]float64{7.77, 49.39, 10.24, 51.66}, 20, [2]float64{8.68, 50.11}},
	{"rhineland", "GeoBasis-DE/LVermGeoRP (dl-de/by-2.0)", wms("https://geo4.service24.rlp.de/wms/rp_dop20.fcgi", "rp_dop20"), [4]float64{6.11, 48.97, 8.51, 50.94}, 20, [2]float64{8.27, 49.99}},
	{"baden", "LGL Baden-Württemberg (dl-de/by-2.0)", wms("https://owsproxy.lgl-bw.de/owsproxy/ows/WMS_LGL-BW_ATKIS_DOP_20_C", "IMAGES_DOP_20_C"), [4]float64{7.51, 47.53, 10.50, 49.79}, 20, [2]float64{9.18, 48.78}},
	{"bavaria", "Bayerische Vermessungsverwaltung (CC BY 4.0)", wms("https://geoservices.bayern.de/od/wms/dop/v1/dop40", "by_dop40c"), [4]float64{8.97, 47.27, 13.84, 50.57}, 19, [2]float64{11.576, 48.137}},
	{"lower-saxony", "LGLN Niedersachsen (CC BY 4.0)", wms("https://opendata.lgln.niedersachsen.de/doorman/noauth/dop_wms", "ni_dop20"), [4]float64{6.65, 51.29, 11.60, 53.90}, 20, [2]float64{9.73, 52.37}},
	{"mecklenburg", "GeoBasis-DE/M-V", wms("https://www.geodaten-mv.de/dienste/adv_dop", "mv_dop"), [4]float64{10.59, 53.11, 14.42, 54.69}, 20, [2]float64{11.41, 53.63}},
	{"austria", "basemap.at (CC BY 4.0)", "https://mapsneu.wien.gv.at/basemap/bmaporthofoto30cm/normal/google3857/{z}/{y}/{x}.jpeg", [4]float64{9.53, 46.37, 17.17, 49.02}, 19, [2]float64{16.37, 48.21}},
	{"czechia", "ČÚZK", wms("https://ags.cuzk.cz/arcgis1/services/ORTOFOTO/MapServer/WMSServer", "0"), [4]float64{12.09, 48.55, 18.86, 51.06}, 19, [2]float64{14.42, 50.09}},
	{"poland", "GUGiK, geoportal.gov.pl", wms("https://mapy.geoportal.gov.pl/wss/service/PZGIK/ORTO/WMS/StandardResolution", "Raster"), [4]float64{14.12, 49.00, 24.15, 54.84}, 19, [2]float64{21.01, 52.23}},
	{"estonia", "Maa-amet, Estonia", wms("https://kaart.maaamet.ee/wms/fotokaart", "EESTIFOTO"), [4]float64{21.76, 57.51, 28.21, 59.70}, 19, [2]float64{24.75, 59.44}},
	{"spain", "PNOA, IGN España (CC BY 4.0)", wms("https://www.ign.es/wms-inspire/pnoa-ma", "OI.OrthoimageCoverage"), [4]float64{-9.35, 35.95, 3.35, 43.80}, 19, [2]float64{-3.70, 40.42}},
	{"france", "IGN, Géoplateforme (Licence Ouverte)", wms("https://data.geopf.fr/wms-r/wms", "ORTHOIMAGERY.ORTHOPHOTOS"), [4]float64{-5.15, 41.33, 8.24, 51.09}, 20, [2]float64{2.35, 48.857}},
	{"japan", "Geospatial Information Authority of Japan (GSI)", "https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg", [4]float64{128.0, 30.0, 146.0, 45.6}, 18, [2]float64{139.767, 35.681}},
	{"usa", "USGS / USDA NAIP (public domain)", "https://imagery.nationalmap.gov/arcgis/rest/services/USGSNAIPImagery/ImageServer/exportImage?bbox={bbox}&bboxSR=3857&imageSR=3857&size=256,256&format=png&f=image", [4]float64{-124.8, 24.5, -66.9, 49.4}, 18, [2]float64{-73.985, 40.748}},
}

func check(s source) (string, bool) {
	const z = 17
	n := math.Exp2(z)
	x := int((s.test[0] + 180) / 360 * n)
	rad := s.test[1] * math.Pi / 180
	y := int((1 - math.Log(math.Tan(rad)+1/math.Cos(rad))/math.Pi) / 2 * n)
	const world = 20037508.342789244
	size := 2 * world / n
	minx, maxy := -world+float64(x)*size, world-float64(y)*size
	u := strings.NewReplacer("{bbox}", fmt.Sprintf("%.4f,%.4f,%.4f,%.4f", minx, maxy-size, minx+size, maxy),
		"{z}", fmt.Sprint(z), "{x}", fmt.Sprint(x), "{y}", fmt.Sprint(y)).Replace(s.Template)
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return err.Error(), false
	}
	req.Header.Set("User-Agent", "FEGlobe-orthocheck/1.0")
	r, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return "no answer", false
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return r.Status, false
	}
	im, _, err := image.Decode(io.LimitReader(r.Body, 8<<20))
	if err != nil {
		return "not a picture (" + r.Header.Get("Content-Type") + ")", false
	}
	// a blank picture has (almost) one colour
	var sum, sum2, c float64
	for py := 0; py < im.Bounds().Dy(); py += 4 {
		for px := 0; px < im.Bounds().Dx(); px += 4 {
			cr, cg, cb, _ := im.At(px, py).RGBA()
			v := float64(cr>>8+cg>>8+cb>>8) / 3
			sum, sum2, c = sum+v, sum2+v*v, c+1
		}
	}
	spread := math.Sqrt(math.Max(0, sum2/c-(sum/c)*(sum/c)))
	return fmt.Sprintf("picture, spread %.0f", spread), spread > 8
}

func main() {
	var good []source
	for _, s := range candidates {
		why, ok := check(s)
		mark := "no "
		if ok {
			mark = "OK "
			if len(good) == 0 || !(s.ID == "berlin2024" && good[len(good)-1].ID == "berlin") {
				good = append(good, s)
			}
		}
		fmt.Printf("%s %-14s %s\n", mark, s.ID, why)
	}
	b, _ := json.MarshalIndent(good, "", " ")
	if err := os.MkdirAll("FEGlobe/Sources/FEGlobe/Resources", 0o755); err != nil {
		panic(err)
	}
	if err := os.WriteFile("FEGlobe/Sources/FEGlobe/Resources/aerial.json", b, 0o644); err != nil {
		panic(err)
	}
	fmt.Println(len(good), "sources written")
}
