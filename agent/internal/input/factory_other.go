//go:build !linux

package input

// NewDefaultInjector returns a no-op injector on unsupported platforms.
func NewDefaultInjector(display string) Injector {
	return NewStubInjector()
}
