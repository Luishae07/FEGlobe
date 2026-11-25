// SPDX-License-Identifier: MPL-2.0
// Draws the app icon (a globe with its lines of latitude and longitude): go run ./tools/icon
package main

import (
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
)

func main() {
	const n = 1024
	img := image.NewRGBA(image.Rect(0, 0, n, n))
	for py := 0; py < n; py++ {
		for px := 0; px < n; px++ {
			var r, g, b float64
			for s := 0; s < 4; s++ { // four samples a pixel: smooth edges
				x := (float64(px) + 0.25 + 0.5*float64(s%2) - n/2) / (n * 0.37)
				y := (n/2 - float64(py) - 0.25 - 0.5*float64(s/2)) / (n * 0.37)
				cr, cg, cb := 8.0, 14.0, 30.0
				d := math.Hypot(x, y)
				if d <= 1 {
					z := math.Sqrt(1 - d*d)
					tilt := 0.35
					lat := math.Asin(y*math.Cos(tilt)+z*math.Sin(tilt)) * 180 / math.Pi
					lon := math.Atan2(x, z*math.Cos(tilt)-y*math.Sin(tilt)) * 180 / math.Pi
					light := math.Max(0, math.Min(1, 0.35+0.65*(-0.45*x+0.45*y+0.77*z)))
					cr, cg, cb = 20+30*light, 60+120*light, 120+135*light
					near := func(a, step float64) float64 { m := math.Mod(math.Abs(a), step); return math.Min(m, step-m) }
					if near(lat, 30) < 0.9 || near(lon, 30) < 0.9/math.Max(0.25, math.Cos(lat*math.Pi/180)) {
						cr, cg, cb = cr+150*light, cg+120*light, cb+60*light
					}
				} else if d < 1.12 {
					k := math.Pow(1-(d-1)/0.12, 2)
					cr, cg, cb = cr+60*k, cg+120*k, cb+210*k
				}
				r += math.Min(255, cr) / 4
				g += math.Min(255, cg) / 4
				b += math.Min(255, cb) / 4
			}
			img.Set(px, py, color.RGBA{uint8(r), uint8(g), uint8(b), 255})
		}
	}
	f, err := os.Create("Resources/Assets.xcassets/AppIcon.appiconset/icon.png")
	if err != nil {
		panic(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		panic(err)
	}
}
