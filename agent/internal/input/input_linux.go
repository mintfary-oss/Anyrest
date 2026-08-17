//go:build linux

package input

import (
	"fmt"
	"math"
	"os/exec"
	"strconv"
)

// LinuxInjector uses xdotool to inject events via the X11 XTEST extension.
// xdotool must be installed: apt-get install -y xdotool
type LinuxInjector struct {
	display string // e.g. ":0"
}

// NewLinuxInjector creates an injector for the given X display (default ":0").
func NewLinuxInjector(display string) *LinuxInjector {
	if display == "" {
		display = ":0"
	}
	return &LinuxInjector{display: display}
}

func (l *LinuxInjector) xdo(args ...string) error {
	cmd := exec.Command("xdotool", args...)
	cmd.Env = append(cmd.Environ(), "DISPLAY="+l.display)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("xdotool %v: %w (%s)", args, err, string(out))
	}
	return nil
}

// MouseMove moves the cursor to absolute pixel coordinates.
func (l *LinuxInjector) MouseMove(x, y int) error {
	return l.xdo("mousemove", "--sync", strconv.Itoa(x), strconv.Itoa(y))
}

// MouseDown presses a mouse button. Buttons: 0→1, 1→2, 2→3.
func (l *LinuxInjector) MouseDown(button int) error {
	return l.xdo("mousedown", strconv.Itoa(button+1))
}

// MouseUp releases a mouse button.
func (l *LinuxInjector) MouseUp(button int) error {
	return l.xdo("mouseup", strconv.Itoa(button+1))
}

// Scroll emits mouse wheel events. One xdotool click = one notch.
func (l *LinuxInjector) Scroll(dx, dy int) error {
	// xdotool uses button 4 (up), 5 (down), 6 (left), 7 (right)
	notchY := int(math.Round(float64(dy) / 120.0))
	notchX := int(math.Round(float64(dx) / 120.0))

	var err error
	if notchY > 0 {
		for i := 0; i < notchY; i++ {
			err = l.xdo("click", "5") // scroll down
		}
	} else if notchY < 0 {
		for i := 0; i > notchY; i-- {
			err = l.xdo("click", "4") // scroll up
		}
	}
	if notchX > 0 {
		for i := 0; i < notchX; i++ {
			err = l.xdo("click", "7") // scroll right
		}
	} else if notchX < 0 {
		for i := 0; i > notchX; i-- {
			err = l.xdo("click", "6") // scroll left
		}
	}
	return err
}

// KeyDown presses a key using xdotool key names.
func (l *LinuxInjector) KeyDown(key, code string) error {
	xkey := jsKeyToXdotool(key, code)
	if xkey == "" {
		return nil // unmapped key — ignore
	}
	return l.xdo("keydown", xkey)
}

// KeyUp releases a key.
func (l *LinuxInjector) KeyUp(key, code string) error {
	xkey := jsKeyToXdotool(key, code)
	if xkey == "" {
		return nil
	}
	return l.xdo("keyup", xkey)
}

// jsKeyToXdotool converts a JavaScript KeyboardEvent.key / code to
// an xdotool-compatible key name.
func jsKeyToXdotool(key, code string) string {
	// Common direct mappings
	switch key {
	case "Enter":        return "Return"
	case "Escape":       return "Escape"
	case "Backspace":    return "BackSpace"
	case "Delete":       return "Delete"
	case "Tab":          return "Tab"
	case "ArrowUp":      return "Up"
	case "ArrowDown":    return "Down"
	case "ArrowLeft":    return "Left"
	case "ArrowRight":   return "Right"
	case "Home":         return "Home"
	case "End":          return "End"
	case "PageUp":       return "Prior"
	case "PageDown":     return "Next"
	case "Insert":       return "Insert"
	case "Control":      return "ctrl"
	case "Alt":          return "alt"
	case "Shift":        return "shift"
	case "Meta":         return "super"
	case "CapsLock":     return "Caps_Lock"
	case "F1":  return "F1"
	case "F2":  return "F2"
	case "F3":  return "F3"
	case "F4":  return "F4"
	case "F5":  return "F5"
	case "F6":  return "F6"
	case "F7":  return "F7"
	case "F8":  return "F8"
	case "F9":  return "F9"
	case "F10": return "F10"
	case "F11": return "F11"
	case "F12": return "F12"
	case " ":   return "space"
	}

	// For printable single characters, xdotool accepts them directly
	if len(key) == 1 {
		r := rune(key[0])
		if r >= 'a' && r <= 'z' {
			return key
		}
		if r >= 'A' && r <= 'Z' {
			return key
		}
		if r >= '0' && r <= '9' {
			return key
		}
		// Symbols — pass through
		return key
	}

	// Fall back to code (e.g. "KeyA" → ignore, mapped above via key)
	_ = code
	return ""
}
