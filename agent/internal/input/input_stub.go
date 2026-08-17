//go:build !linux

package input

import "errors"

// StubInjector is a no-op for unsupported platforms.
type StubInjector struct{}

func NewStubInjector() *StubInjector { return &StubInjector{} }

var errUnsupported = errors.New("input injection not supported on this platform")

func (s *StubInjector) MouseMove(x, y int) error           { return errUnsupported }
func (s *StubInjector) MouseDown(button int) error         { return errUnsupported }
func (s *StubInjector) MouseUp(button int) error           { return errUnsupported }
func (s *StubInjector) Scroll(dx, dy int) error            { return errUnsupported }
func (s *StubInjector) KeyDown(key, code string) error     { return errUnsupported }
func (s *StubInjector) KeyUp(key, code string) error       { return errUnsupported }
