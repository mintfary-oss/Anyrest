// Package input provides keyboard and mouse injection.
// The concrete implementation is chosen at compile time based on build tags.
package input

// Injector injects keyboard and mouse events into the local display.
type Injector interface {
	// MouseMove moves the cursor to the given absolute pixel coordinates.
	MouseMove(x, y int) error
	// MouseDown presses the given mouse button (0=left, 1=middle, 2=right).
	MouseDown(button int) error
	// MouseUp releases the given mouse button.
	MouseUp(button int) error
	// Scroll scrolls by (dx, dy) where negative dy means up/forward.
	Scroll(dx, dy int) error
	// KeyDown presses a key identified by its X11/JS key name.
	KeyDown(key, code string) error
	// KeyUp releases a key.
	KeyUp(key, code string) error
}
