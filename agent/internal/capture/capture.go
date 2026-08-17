// Package capture provides cross-platform screen capture.
// Frames are captured as JPEG-encoded bytes and delivered on a channel
// so the caller can throttle to a desired frame rate.
package capture

import (
	"bytes"
	"fmt"
	"image"
	"image/jpeg"

	"github.com/kbinani/screenshot"
	xdraw "golang.org/x/image/draw"
)

const (
	// DefaultQuality is the JPEG quality (0-100) used when encoding frames.
	DefaultQuality = 75
	// MaxWidth / MaxHeight caps the output resolution for bandwidth control.
	MaxWidth  = 1280
	MaxHeight = 720
)

// Capturer grabs the desktop screen and returns JPEG-encoded frames.
type Capturer struct {
	displayIdx int
	quality    int
}

// New creates a Capturer for the given display index (0 = primary).
func New(displayIdx, quality int) *Capturer {
	if quality <= 0 || quality > 100 {
		quality = DefaultQuality
	}
	return &Capturer{displayIdx: displayIdx, quality: quality}
}

// Frame holds a single captured + encoded frame.
type Frame struct {
	JPEG   []byte
	Width  int
	Height int
}

// Capture takes a single screenshot and returns it as JPEG bytes.
// It automatically scales the image down if it exceeds MaxWidth×MaxHeight.
func (c *Capturer) Capture() (*Frame, error) {
	n := screenshot.NumActiveDisplays()
	if n == 0 {
		return nil, fmt.Errorf("no active displays found")
	}
	idx := c.displayIdx
	if idx >= n {
		idx = 0
	}

	bounds := screenshot.GetDisplayBounds(idx)
	img, err := screenshot.CaptureRect(bounds)
	if err != nil {
		return nil, fmt.Errorf("capture display %d: %w", idx, err)
	}

	// Scale down if needed
	scaled := scaleDown(img, MaxWidth, MaxHeight)

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, scaled, &jpeg.Options{Quality: c.quality}); err != nil {
		return nil, fmt.Errorf("jpeg encode: %w", err)
	}

	return &Frame{
		JPEG:   buf.Bytes(),
		Width:  scaled.Bounds().Dx(),
		Height: scaled.Bounds().Dy(),
	}, nil
}

// DisplayCount returns the number of active displays.
func DisplayCount() int {
	return screenshot.NumActiveDisplays()
}

// scaleDown returns a scaled-down version of src if it exceeds maxW×maxH.
// If src is already within bounds, it is returned unchanged.
func scaleDown(src image.Image, maxW, maxH int) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= maxW && h <= maxH {
		return src
	}

	// Calculate target size preserving aspect ratio
	ratioW := float64(maxW) / float64(w)
	ratioH := float64(maxH) / float64(h)
	ratio := ratioW
	if ratioH < ratio {
		ratio = ratioH
	}

	dstW := int(float64(w) * ratio)
	dstH := int(float64(h) * ratio)
	if dstW < 1 {
		dstW = 1
	}
	if dstH < 1 {
		dstH = 1
	}

	dst := image.NewRGBA(image.Rect(0, 0, dstW, dstH))
	xdraw.BiLinear.Scale(dst, dst.Bounds(), src, b, xdraw.Src, nil)
	return dst
}
