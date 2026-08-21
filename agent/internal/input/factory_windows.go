//go:build windows

package input

// NewDefaultInjector returns a WindowsInjector on Windows.
// The display argument is unused on Windows (no X11 display concept).
func NewDefaultInjector(display string) Injector {
	return NewWindowsInjector()
}
