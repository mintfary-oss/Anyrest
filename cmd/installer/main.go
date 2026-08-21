// Anyrest Windows Installer
//
// Self-contained .exe that embeds install.ps1 and executes it via PowerShell.
// Build (on Linux, targeting Windows):
//
//	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
//	  go build -ldflags="-s -w -H windowsgui" \
//	  -o ../../bin/windows-amd64/anyrest-installer.exe .
//
// Or with a console window (easier to see output):
//
//	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
//	  go build -ldflags="-s -w" \
//	  -o ../../bin/windows-amd64/anyrest-installer.exe .
//
// Usage (double-click or run from cmd.exe):
//
//	anyrest-installer.exe                      (agent mode, asks for server IP)
//	anyrest-installer.exe -ServerIP 1.2.3.4   (agent, connects to 1.2.3.4)
//	anyrest-installer.exe -ServerMode          (full server via Docker)
package main

import (
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// install.ps1 is embedded at build time — no external files needed.
// This file is a copy of the root install.ps1; kept in sync during releases.
//
//go:embed install.ps1
var installScript []byte

func main() {
	fmt.Println("════════════════════════════════════════════════════")
	fmt.Println("  Anyrest Installer v1 — Windows")
	fmt.Println("════════════════════════════════════════════════════")
	fmt.Println()

	// Write embedded PS1 to a temporary file.
	tmp, err := os.CreateTemp("", "anyrest-install-*.ps1")
	if err != nil {
		fatalf("Ошибка создания временного файла: %v", err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)

	if _, err = tmp.Write(installScript); err != nil {
		fatalf("Ошибка записи скрипта: %v", err)
	}
	tmp.Close()

	// Forward all arguments from the installer to the PS1 script.
	// Example: anyrest-installer.exe -ServerIP 1.2.3.4 -ServerMode
	psArgs := []string{
		"-ExecutionPolicy", "Bypass",
		"-NoProfile",
		"-NonInteractive",
		"-File", filepath.ToSlash(tmpPath),
	}
	psArgs = append(psArgs, os.Args[1:]...)

	cmd := exec.Command("powershell.exe", psArgs...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin

	fmt.Println("  Запускаю PowerShell установщик...")
	fmt.Println()

	if err := cmd.Run(); err != nil {
		// PowerShell exited with non-zero — it already printed the error.
		fmt.Fprintln(os.Stderr, "\n  Установка завершилась с ошибкой.")
		fmt.Fprintln(os.Stderr, "  Запустите PowerShell от имени Администратора и повторите.")
		os.Exit(1)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "  ОШИБКА: "+format+"\n", args...)
	fmt.Fprintln(os.Stderr, "  Нажмите Enter для выхода.")
	fmt.Scanln() //nolint:errcheck
	os.Exit(1)
}
