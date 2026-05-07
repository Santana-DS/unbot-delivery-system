// cmd/gateway/main.go
//
// Entry point. Wires config → mqtt → services → api → signal handling.
// No business logic lives here.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"unbot-gateway/internal/api"
	"unbot-gateway/internal/config"
	mqttclient "unbot-gateway/internal/mqtt"
	"unbot-gateway/internal/services"
)

func main() {
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
		log.Error("MQTT connect failed", "error", err)
		os.Exit(1)
	}

	// ── Service layer ─────────────────────────────────────────────────────
	// mqtt.Client satisfies services.Publisher via duck typing.
	// main.go is the only place that knows about both packages — no import
	// cycle, no tight coupling between api/mqtt/services.
	otpSvc := services.NewOTPService(mqtt)

	// ── HTTP server ───────────────────────────────────────────────────────
	srv := api.NewServer(cfg.HTTPAddr, log, otpSvc)
	srv.Start()

	log.Info("gateway ready",
		"unlock_topic", "robot/commands/unlock",
		"validate_endpoint", "POST /api/validate-code",
	)

	// ── Block on signal ───────────────────────────────────────────────────
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Info("shutdown signal received — draining...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("HTTP shutdown error", "error", err)
	}

	mqtt.Disconnect()
	log.Info("gateway stopped cleanly")
}
