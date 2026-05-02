// cmd/gateway/main.go
//
// UnBot Delivery — Gateway v2.0 (Go)
// Entry point. Responsibilities are strictly limited to:
//   1. Load config.
//   2. Wire dependencies (MQTT client, HTTP server).
//   3. Start subsystems.
//   4. Block on OS signal.
//   5. Drain subsystems in reverse-start order on shutdown.
//
// No business logic lives here. All domain behaviour belongs in /internal.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/unb-ft/unbot-gateway/internal/api"
	"github.com/unb-ft/unbot-gateway/internal/config"
	mqttclient "github.com/unb-ft/unbot-gateway/internal/mqtt"
)

func main() {
	// ── Structured logger ─────────────────────────────────────────────────
	// slog writes JSON to stdout — systemd-journald and cloud log aggregators
	// (CloudWatch, Oracle Logging) ingest this without extra parsing config.
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	// ── Config ────────────────────────────────────────────────────────────
	cfg, err := config.Load()
	if err != nil {
		log.Error("configuration error", "error", err)
		os.Exit(1)
	}
	log.Info("configuration loaded",
		"mqtt_host", cfg.MQTTHost,
		"mqtt_port", cfg.MQTTPort,
		"http_addr", cfg.HTTPAddr,
	)

	// ── MQTT client ───────────────────────────────────────────────────────
	mqtt := mqttclient.NewClient(cfg, log)
	if err := mqtt.Connect(); err != nil {
		// Fatal at startup: without a broker connection the gateway cannot
		// issue OTPs or forward navigation commands. Fail loudly.
		log.Error("MQTT connect failed", "error", err)
		os.Exit(1)
	}

	// ── HTTP server ───────────────────────────────────────────────────────
	srv := api.NewServer(cfg.HTTPAddr, log)
	srv.Start()

	log.Info("gateway ready")

	// ── Block until SIGINT or SIGTERM ─────────────────────────────────────
	// SIGTERM is sent by systemd/Docker on graceful stop.
	// SIGINT  is Ctrl-C during local development.
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Info("shutdown signal received — draining...")

	// ── Graceful shutdown (reverse start order) ───────────────────────────
	// 1. Stop accepting new HTTP requests; drain in-flight with a deadline.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("HTTP shutdown error", "error", err)
	}

	// 2. Send MQTT DISCONNECT so the broker releases the client slot cleanly
	//    and does NOT broadcast the last-will message (clean disconnect).
	mqtt.Disconnect()

	log.Info("gateway stopped cleanly")
}
