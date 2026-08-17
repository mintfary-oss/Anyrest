//go:build linux

package input

// NewDefaultInjector returns a LinuxInjector bound to the given X display.
func NewDefaultInjector(display string) Injector {
	return NewLinuxInjector(display)
}
