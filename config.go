package runcore

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/svanichkin/configobj"
)

// LXMDDiskLayout matches lxmd: configDir/{config,identity,storage/...}.
// runcore additionally creates configDir/rns/config for go-reticulum.
type LXMDDiskLayout struct {
	ConfigDir     string
	ConfigPath    string
	IdentityPath  string
	StorageDir    string
	MessagesDir   string
	RNSConfigDir  string
	RNSConfigPath string
}

func ResolveLayout(configDir string) LXMDDiskLayout {
	return LXMDDiskLayout{
		ConfigDir:     configDir,
		ConfigPath:    filepath.Join(configDir, "config"),
		IdentityPath:  filepath.Join(configDir, "identity"),
		StorageDir:    filepath.Join(configDir, "storage"),
		MessagesDir:   filepath.Join(configDir, "storage", "messages"),
		RNSConfigDir:  filepath.Join(configDir, "rns"),
		RNSConfigPath: filepath.Join(configDir, "rns", "config"),
	}
}

// DefaultLXMDConfigText returns a minimal lxmd-style config template.
// displayName (optional) is used as the default [lxmf] display_name.
func DefaultLXMDConfigText(displayName string) string {
	if displayName == "" {
		displayName = "Me"
	}
	return fmt.Sprintf(defaultLXMDConfigTextFmt, displayName)
}

// EnsureLXMDConfig writes the default `config` file if it doesn't exist.
func EnsureLXMDConfig(configDir string) (LXMDDiskLayout, error) {
	return EnsureLXMDConfigWithDisplayName(configDir, "")
}

// EnsureLXMDConfigWithDisplayName writes the default `config` file if it doesn't exist,
// using displayName as the initial [lxmf] display_name.
func EnsureLXMDConfigWithDisplayName(configDir, displayName string) (LXMDDiskLayout, error) {
	layout := ResolveLayout(configDir)
	if err := os.MkdirAll(layout.ConfigDir, 0o755); err != nil {
		return layout, fmt.Errorf("create config dir: %w", err)
	}
	if _, err := os.Stat(layout.ConfigPath); err == nil {
		return layout, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return layout, fmt.Errorf("stat config: %w", err)
	}
	if err := os.WriteFile(layout.ConfigPath, []byte(DefaultLXMDConfigText(displayName)), 0o644); err != nil {
		return layout, fmt.Errorf("write default config: %w", err)
	}
	return layout, nil
}

// LoadLXMDConfig parses configDir/config and returns a configobj.Config for editing.
func LoadLXMDConfig(configDir string) (*configobj.Config, LXMDDiskLayout, error) {
	layout := ResolveLayout(configDir)
	cfg, err := configobj.Load(layout.ConfigPath)
	if err != nil {
		return nil, layout, err
	}
	return cfg, layout, nil
}

// SaveLXMDConfig validates and saves the config.
func SaveLXMDConfig(cfg *configobj.Config, configDir string) (LXMDDiskLayout, error) {
	if cfg == nil {
		return ResolveLayout(configDir), errors.New("nil config")
	}
	layout := ResolveLayout(configDir)
	if err := os.MkdirAll(layout.ConfigDir, 0o755); err != nil {
		return layout, fmt.Errorf("create config dir: %w", err)
	}
	if err := cfg.Save(layout.ConfigPath); err != nil {
		return layout, err
	}
	return layout, nil
}

// ResetLXMDConfig overwrites configDir/config with DefaultLXMDConfigText().
func ResetLXMDConfig(configDir string) (LXMDDiskLayout, error) {
	return ResetLXMDConfigWithDisplayName(configDir, "")
}

// ResetLXMDConfigWithDisplayName overwrites configDir/config with a minimal template using displayName.
func ResetLXMDConfigWithDisplayName(configDir, displayName string) (LXMDDiskLayout, error) {
	layout := ResolveLayout(configDir)
	if err := os.MkdirAll(layout.ConfigDir, 0o755); err != nil {
		return layout, fmt.Errorf("create config dir: %w", err)
	}
	if err := os.WriteFile(layout.ConfigPath, []byte(DefaultLXMDConfigText(displayName)), 0o644); err != nil {
		return layout, fmt.Errorf("write default config: %w", err)
	}
	return layout, nil
}

// UpdateLXMFDisplayName persists the profile name into configDir/config ([lxmf] display_name).
func UpdateLXMFDisplayName(configDir, displayName string) error {
	if _, err := EnsureLXMDConfigWithDisplayName(configDir, displayName); err != nil {
		return err
	}
	cfg, layout, err := LoadLXMDConfig(configDir)
	if err != nil {
		return err
	}
	if displayName == "" {
		displayName = "Me"
	}
	sec := cfg.Section("lxmf")
	sec.Set("display_name", displayName)
	_, err = SaveLXMDConfig(cfg, layout.ConfigDir)
	return err
}

// DefaultRNSConfigText returns the embedded Reticulum config template used when RNSConfigDir is empty.
func DefaultRNSConfigText(logLevel int) string { return defaultInlineRNSConfig(logLevel) }

// EnsureRNSConfig writes configDir/rns/config from DefaultRNSConfigText if it doesn't exist.
func EnsureRNSConfig(configDir string, logLevel int) (LXMDDiskLayout, error) {
	layout := ResolveLayout(configDir)
	if err := os.MkdirAll(layout.RNSConfigDir, 0o755); err != nil {
		return layout, fmt.Errorf("create rns config dir: %w", err)
	}
	if _, err := os.Stat(layout.RNSConfigPath); err == nil {
		return layout, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return layout, fmt.Errorf("stat rns config: %w", err)
	}
	if err := os.WriteFile(layout.RNSConfigPath, []byte(DefaultRNSConfigText(logLevel)), 0o644); err != nil {
		return layout, fmt.Errorf("write rns config: %w", err)
	}
	return layout, nil
}

// ResetRNSConfig overwrites configDir/rns/config from DefaultRNSConfigText.
func ResetRNSConfig(configDir string, logLevel int) (LXMDDiskLayout, error) {
	layout := ResolveLayout(configDir)
	if err := os.MkdirAll(layout.RNSConfigDir, 0o755); err != nil {
		return layout, fmt.Errorf("create rns config dir: %w", err)
	}
	if err := os.WriteFile(layout.RNSConfigPath, []byte(DefaultRNSConfigText(logLevel)), 0o644); err != nil {
		return layout, fmt.Errorf("write rns config: %w", err)
	}
	return layout, nil
}

const defaultLXMDConfigTextFmt = `[propagation]
enable_node = no
announce_interval = 360
announce_at_start = yes
autopeer = yes
autopeer_maxdepth = 4

[lxmf]
display_name = %s
announce_at_start = no
delivery_transfer_max_accepted_size = 1000

[logging]
loglevel = 4
`
