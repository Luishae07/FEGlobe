// SPDX-License-Identifier: MPL-2.0
// Draws the app icon: the real Earth as a globe, from the Natural Earth II raster with shaded relief (public domain, naturalearthdata.com).
// The raster (NE2_50M_SR_W, whole world, plate carrée) is given as a PNG:  go run tools/icon/main.go -earth earth.png
package main

import (
	"flag"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
)

type vec struct{ x, y, z float64 }

func (a vec) dot(b vec) float64 { return a.x*b.x + a.y*b.y + a.z*b.z }
func (a vec) unit() vec {
	l := math.Sqrt(a.dot(a))
	return vec{a.x / l, a.y / l, a.z / l}
}

func clamp(v float64) float64 { return math.Max(0, math.Min(255, v)) }

func mix(a, b vec, t float64) vec {
	return vec{a.x + (b.x-a.x)*t, a.y + (b.y-a.y)*t, a.z + (b.z-a.z)*t}
}

func main() {
	source := flag.String("earth", "earth.png", "the Natural Earth raster as PNG (twice as wide as high)")
	out := flag.String("out", "Resources/Assets.xcassets/AppIcon.appiconset/icon.png", "the icon")
	flag.Parse()
	f, err := os.Open(*source)
	if err != nil {
		panic(err)
	}
	earth, err := png.Decode(f)
	f.Close()
	if err != nil {
		panic(err)
	}
	w, h := earth.Bounds().Dx(), earth.Bounds().Dy()
	at := func(x, y int) vec {
		x = ((x % w) + w) % w
		y = max(0, min(h-1, y))
		r, g, b, _ := earth.At(x, y).RGBA()
		return vec{float64(r) / 257, float64(g) / 257, float64(b) / 257}
	}
	sample := func(lat, lon float64) vec { // between the four nearest pixels
		fx := (lon+180)/360*float64(w) - 0.5
		fy := (90-lat)/180*float64(h) - 0.5
		x, y := int(math.Floor(fx)), int(math.Floor(fy))
		tx, ty := fx-float64(x), fy-float64(y)
		return mix(mix(at(x, y), at(x+1, y), tx), mix(at(x, y+1), at(x+1, y+1), tx), ty)
	}

	const n, ss = 1024, 3
	const radius = n * 0.40
	lat0, lon0 := 28*math.Pi/180, 14*math.Pi/180 // Europe and Africa in the middle
	light := vec{-0.45, 0.50, 0.74}.unit()
	img := image.NewRGBA(image.Rect(0, 0, n, n))
	for py := 0; py < n; py++ {
		for px := 0; px < n; px++ {
			var sum vec
			for s := 0; s < ss*ss; s++ { // several samples a pixel: smooth edges
				x := (float64(px) + (float64(s%ss)+0.5)/ss - n/2) / radius
				y := (n/2 - float64(py) - (float64(s/ss)+0.5)/ss) / radius
				// the sky: deep blue, a little lighter towards the top
				c := mix(vec{4, 7, 18}, vec{12, 24, 52}, math.Max(0, math.Min(1, 0.5+y*0.35)))
				d := math.Hypot(x, y)
				if d <= 1 {
					z := math.Sqrt(1 - d*d)
					lat := math.Asin(z*math.Sin(lat0) + y*math.Cos(lat0))
					lon := lon0 + math.Atan2(x, z*math.Cos(lat0)-y*math.Sin(lat0))
					lonDeg := math.Mod(lon*180/math.Pi+540, 360) - 180
					c = sample(lat*180/math.Pi, lonDeg)
					// richer colours
					grey := c.x*0.3 + c.y*0.59 + c.z*0.11
					c = vec{grey + (c.x-grey)*1.45, grey + (c.y-grey)*1.45, grey + (c.z-grey)*1.45}
					deeper := func(v float64) float64 { return 255 * math.Pow(clamp(v)/255, 1.35) }
					c = vec{deeper(c.x), deeper(c.y), deeper(c.z)}
					lambert := math.Max(0, vec{x, y, z}.dot(light))
					shade := 0.30 + 0.82*math.Pow(lambert, 0.85)
					c = vec{c.x * shade, c.y * shade, c.z * shade}
					c = mix(c, vec{120, 185, 255}, math.Pow(1-z, 2.6)*0.75) // the air at the rim
				} else if d < 1.16 {
					k := math.Pow(1-(d-1)/0.16, 2.4)
					side := 0.55 + 0.45*math.Max(0, (x*light.x+y*light.y)/d+0.4)
					c = mix(c, vec{90, 165, 255}, math.Min(1, k*0.85*side))
				}
				sum = vec{sum.x + clamp(c.x), sum.y + clamp(c.y), sum.z + clamp(c.z)}
			}
			k := 1.0 / (ss * ss)
			img.Set(px, py, color.RGBA{uint8(sum.x * k), uint8(sum.y * k), uint8(sum.z * k), 255})
		}
	}
	o, err := os.Create(*out)
	if err != nil {
		panic(err)
	}
	defer o.Close()
	if err := png.Encode(o, img); err != nil {
		panic(err)
	}
}
