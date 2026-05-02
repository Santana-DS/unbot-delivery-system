// internal/config/config.go
//
// Loads all runtime configuration from environment variables.
// The .env file is optional — in production, variables are injected
// directly by the cloud VM's environment (systemd EnvironmentFile,
// Docker --env-file, etc.). godotenv is a no-op if the file is absent.
//
// All fields are validated at startup so the process fails fast with a
// clear error rather than panicking mid-request on a missing credential.
package config

import (
	"fmt"
	"os"
	"strconv"

	"github.com/joho/godotenv"
)

// Config holds every runtime parameter the gateway needs.
// Add new fields here; never read os.Getenv() outside this package.
type Config struct {
	// MQTT broker connection
	MQTTHost     string
	MQTTPort     int
	MQTTUser     string
	MQTTPassword string
	MQTTClientID string

	// HTTP API listener
	HTTPAddr string
}

// Load reads the .env file (if present) then validates required variables.
// Returns a fully populated Config or a descriptive error.
func Load() (*Config, error) {
	// godotenv.Load is intentionally non-fatal when .env is absent —
	// production environments inject vars directly.
	_ = godotenv.Load()

	cfg := &Config{}
	var missing []string

	cfg.MQTTHost = requireEnv("MQTT_HOST", &missing)
	cfg.MQTTUser = requireEnv("MQTT_USER", &missing)
	cfg.MQTTPassword = requireEnv("MQTT_PASSWORD", &missing)

	if len(missing) > 0 {
		return nil, fmt.Errorf("missing required environment variables: %v", missing)
	}

	// Optional with sensible defaults.
	cfg.MQTTPort = optionalInt("MQTT_PORT", 1883)
	cfg.MQTTClientID = optionalStr("MQTT_CLIENT_ID", "unbot-gateway")
	cfg.HTTPAddr = optionalStr("HTTP_ADDR", ":8080")

	return cfg, nil
}

// BrokerURL returns the full paho broker address string.
func (c *Config) BrokerURL() string {
	return fmt.Sprintf("tcp://%s:%d", c.MQTTHost, c.MQTTPort)
}

// ── helpers ──────────────────────────────────────────────────────────────────

func requireEnv(key string, missing *[]string) string {
	v := os.Getenv(key)
	if v == "" {
		*missing = append(*missing, key)
	}
	return v
}

func optionalStr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func optionalInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return n
}
