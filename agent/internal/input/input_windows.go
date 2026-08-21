//go:build windows

// Package input — Windows implementation using Win32 SendInput API.
// No CGO required: all Win32 calls go through syscall (pure Go).
package input

import (
	"encoding/binary"
	"fmt"
	"syscall"
	"unsafe"
)

// Win32 constants ─────────────────────────────────────────────────────────────

const (
	inputMouse    = 0
	inputKeyboard = 1

	// Mouse event flags
	mouseMoveAbs   = 0x8001 // MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE
	mouseLeftDown  = 0x0002 // MOUSEEVENTF_LEFTDOWN
	mouseLeftUp    = 0x0004 // MOUSEEVENTF_LEFTUP
	mouseRightDown = 0x0008 // MOUSEEVENTF_RIGHTDOWN
	mouseRightUp   = 0x0010 // MOUSEEVENTF_RIGHTUP
	mouseMiddDown  = 0x0020 // MOUSEEVENTF_MIDDLEDOWN
	mouseMiddUp    = 0x0040 // MOUSEEVENTF_MIDDLEUP
	mouseWheel     = 0x0800 // MOUSEEVENTF_WHEEL
	mouseHWheel    = 0x1000 // MOUSEEVENTF_HWHEEL

	// Keyboard event flags
	keyeventfKeyUp   = 0x0002
	keyeventfUnicode = 0x0004

	// GetSystemMetrics
	smCxScreen = 0
	smCyScreen = 1

	// One scroll notch
	wheelDelta = 120
)

// Lazy-loaded user32 procs ─────────────────────────────────────────────────────

var (
	user32              = syscall.NewLazyDLL("user32.dll")
	procSendInput       = user32.NewProc("SendInput")
	procGetSystemMetrics = user32.NewProc("GetSystemMetrics")
)

// WindowsInjector implements Injector using Win32 SendInput.
type WindowsInjector struct{}

// NewWindowsInjector returns a WindowsInjector.
func NewWindowsInjector() *WindowsInjector { return &WindowsInjector{} }

// ── INPUT struct layout (64-bit Windows) ─────────────────────────────────────
// Offset  0- 3: type       DWORD
// Offset  4- 7: [padding]
// Offset  8-11: mi.dx / ki.wVk+wScan   (LONG / WORD+WORD)
// Offset 12-15: mi.dy / ki.dwFlags     (LONG / DWORD)
// Offset 16-19: mi.mouseData / ki.time (DWORD / DWORD)
// Offset 20-23: mi.dwFlags / [padding] (DWORD / 4)
// Offset 24-27: mi.time                (DWORD)
// Offset 28-31: [padding]
// Offset 32-39: mi.dwExtraInfo / ki.dwExtraInfo (ULONG_PTR / ULONG_PTR)
// Total: 40 bytes

const inputSize = 40

// sendInput calls Win32 SendInput with a single 40-byte INPUT record.
func sendInput(rec [inputSize]byte) error {
	n, _, err := procSendInput.Call(
		1,                                          // nInputs
		uintptr(unsafe.Pointer(&rec[0])),           // pInputs
		uintptr(inputSize),                         // cbSize
	)
	if n != 1 {
		return fmt.Errorf("SendInput returned %d: %w", n, err)
	}
	return nil
}

// mouseInput builds an INPUT record of type INPUT_MOUSE.
func mouseInput(flags uint32, dx, dy int32, data uint32) [inputSize]byte {
	var buf [inputSize]byte
	binary.LittleEndian.PutUint32(buf[0:4], inputMouse) // type
	// offset 4-7: padding (zero)
	binary.LittleEndian.PutUint32(buf[8:12], uint32(dx))    // mi.dx
	binary.LittleEndian.PutUint32(buf[12:16], uint32(dy))   // mi.dy
	binary.LittleEndian.PutUint32(buf[16:20], data)         // mi.mouseData
	binary.LittleEndian.PutUint32(buf[20:24], flags)        // mi.dwFlags
	// time, extraInfo: zero
	return buf
}

// kbdInput builds an INPUT record of type INPUT_KEYBOARD.
func kbdInput(vk, scan uint16, flags uint32) [inputSize]byte {
	var buf [inputSize]byte
	binary.LittleEndian.PutUint32(buf[0:4], inputKeyboard)
	binary.LittleEndian.PutUint16(buf[8:10], vk)      // ki.wVk
	binary.LittleEndian.PutUint16(buf[10:12], scan)   // ki.wScan
	binary.LittleEndian.PutUint32(buf[12:16], flags)  // ki.dwFlags
	// time, extraInfo: zero
	return buf
}

// screenSize returns the primary screen dimensions from GetSystemMetrics.
func screenSize() (w, h int32) {
	cxRaw, _, _ := procGetSystemMetrics.Call(smCxScreen)
	cyRaw, _, _ := procGetSystemMetrics.Call(smCyScreen)
	w, h = int32(cxRaw), int32(cyRaw)
	if w <= 0 {
		w = 1920
	}
	if h <= 0 {
		h = 1080
	}
	return
}

// ── Injector interface ────────────────────────────────────────────────────────

// MouseMove moves the cursor to absolute pixel (x, y).
// SendInput MOUSEEVENTF_ABSOLUTE uses 0-65535 normalised coordinates.
func (w *WindowsInjector) MouseMove(x, y int) error {
	sw, sh := screenSize()
	// Normalise: (x * 65535) / (screenW - 1)
	nx := int32(x) * 65535 / (sw - 1)
	ny := int32(y) * 65535 / (sh - 1)
	rec := mouseInput(mouseMoveAbs, nx, ny, 0)
	return sendInput(rec)
}

// MouseDown presses a mouse button. button: 0=left, 1=middle, 2=right.
func (w *WindowsInjector) MouseDown(button int) error {
	flags := [3]uint32{mouseLeftDown, mouseMiddDown, mouseRightDown}
	if button < 0 || button > 2 {
		return nil
	}
	return sendInput(mouseInput(flags[button], 0, 0, 0))
}

// MouseUp releases a mouse button.
func (w *WindowsInjector) MouseUp(button int) error {
	flags := [3]uint32{mouseLeftUp, mouseMiddUp, mouseRightUp}
	if button < 0 || button > 2 {
		return nil
	}
	return sendInput(mouseInput(flags[button], 0, 0, 0))
}

// Scroll emits mouse wheel events.
// dy > 0 → scroll down, dy < 0 → scroll up.
// dx > 0 → scroll right, dx < 0 → scroll left.
func (w *WindowsInjector) Scroll(dx, dy int) error {
	if dy != 0 {
		// Invert: positive dy = scroll down = negative WHEEL_DELTA
		delta := uint32(-int32(wheelDelta) * int32(dy) / wheelDelta)
		if err := sendInput(mouseInput(mouseWheel, 0, 0, delta)); err != nil {
			return err
		}
	}
	if dx != 0 {
		delta := uint32(int32(wheelDelta) * int32(dx) / wheelDelta)
		if err := sendInput(mouseInput(mouseHWheel, 0, 0, delta)); err != nil {
			return err
		}
	}
	return nil
}

// KeyDown sends a key-down event.
func (w *WindowsInjector) KeyDown(key, code string) error {
	vk := jsKeyToVK(key, code)
	if vk == 0 {
		// Fallback: send as Unicode character
		if len(key) == 1 {
			return sendInput(kbdInput(0, uint16(rune(key[0])), keyeventfUnicode))
		}
		return nil
	}
	return sendInput(kbdInput(vk, 0, 0))
}

// KeyUp sends a key-up event.
func (w *WindowsInjector) KeyUp(key, code string) error {
	vk := jsKeyToVK(key, code)
	if vk == 0 {
		if len(key) == 1 {
			return sendInput(kbdInput(0, uint16(rune(key[0])), keyeventfUnicode|keyeventfKeyUp))
		}
		return nil
	}
	return sendInput(kbdInput(vk, 0, keyeventfKeyUp))
}

// jsKeyToVK maps JavaScript KeyboardEvent.key / code to a Win32 Virtual Key code.
// Reference: https://docs.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
func jsKeyToVK(key, code string) uint16 {
	switch key {
	case "Enter":      return 0x0D // VK_RETURN
	case "Escape":     return 0x1B // VK_ESCAPE
	case "Backspace":  return 0x08 // VK_BACK
	case "Delete":     return 0x2E // VK_DELETE
	case "Tab":        return 0x09 // VK_TAB
	case "ArrowLeft":  return 0x25 // VK_LEFT
	case "ArrowUp":    return 0x26 // VK_UP
	case "ArrowRight": return 0x27 // VK_RIGHT
	case "ArrowDown":  return 0x28 // VK_DOWN
	case "Home":       return 0x24 // VK_HOME
	case "End":        return 0x23 // VK_END
	case "PageUp":     return 0x21 // VK_PRIOR
	case "PageDown":   return 0x22 // VK_NEXT
	case "Insert":     return 0x2D // VK_INSERT
	case "Control":    return 0x11 // VK_CONTROL
	case "Alt":        return 0x12 // VK_MENU
	case "Shift":      return 0x10 // VK_SHIFT
	case "Meta":       return 0x5B // VK_LWIN
	case "CapsLock":   return 0x14 // VK_CAPITAL
	case "F1":         return 0x70
	case "F2":         return 0x71
	case "F3":         return 0x72
	case "F4":         return 0x73
	case "F5":         return 0x74
	case "F6":         return 0x75
	case "F7":         return 0x76
	case "F8":         return 0x77
	case "F9":         return 0x78
	case "F10":        return 0x79
	case "F11":        return 0x7A
	case "F12":        return 0x7B
	case " ":          return 0x20 // VK_SPACE
	}

	// Single printable ASCII → VkKeyScanA returns the VK code
	// We use a static table to avoid a Win32 call per keystroke.
	if len(key) == 1 {
		c := key[0]
		if c >= '0' && c <= '9' {
			return uint16(c) // VK_0..VK_9 == ASCII '0'..'9'
		}
		if c >= 'a' && c <= 'z' {
			return uint16(c - 32) // VK_A..VK_Z == ASCII 'A'..'Z'
		}
		if c >= 'A' && c <= 'Z' {
			return uint16(c) // already uppercase
		}
		// For symbols, use VkKeyScanA at runtime if available.
		// Calling it here would require a syscall per event — we use 0
		// and let the Unicode fallback in KeyDown/KeyUp handle it.
		return 0
	}

	_ = code
	return 0
}
