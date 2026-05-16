// cmd/gateway/main.go
//
// CHANGES IN THIS REVISION (Phase 1.5):
//   - WakeDisplayService constructed and injected into api.NewServer.
//     All other wiring is unchanged.
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
	otpSvc := services.NewOTPService(mqtt)
	orderSvc := services.NewOrderService(otpSvc, mqtt, log)
	wakeSvc := services.NewWakeDisplayService(otpSvc, mqtt, log) // NEW

	// ── HTTP server ───────────────────────────────────────────────────────
	srv := api.NewServer(cfg.HTTPAddr, log, otpSvc, orderSvc, wakeSvc)
	srv.Start()

	log.Info("gateway ready",
		"endpoints", []string{
			"GET  /health",
			"POST /api/validate-code",
			"POST /api/orders/{id}/dispatch",
			"POST /api/orders/{id}/wake-display", // NEW
		},
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
