// internal/api/server.go
//
// CHANGES IN THIS REVISION (Phase 1.5):
//   - NewServer accepts *services.WakeDisplayService as a fourth parameter.
//   - routes() registers "POST /api/orders/{id}/wake-display".
//     All other logic is unchanged.
package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"unbot-gateway/internal/services"
)

type Server struct {
	addr   string
	log    *slog.Logger
	mux    *http.ServeMux
	server *http.Server
}

// NewServer constructs the server and registers all routes.
// CHANGED: wakeSvc added as fourth parameter.
func NewServer(
	addr string,
	log *slog.Logger,
	otpSvc *services.OTPService,
	orderSvc *services.OrderService,
	wakeSvc *services.WakeDisplayService, // NEW
) *Server {
	s := &Server{
		addr: addr,
		log:  log,
		mux:  http.NewServeMux(),
	}
	s.routes(otpSvc, orderSvc, wakeSvc)
	s.server = &http.Server{
		Addr:         addr,
		Handler:      s.mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}
	return s
}

func (s *Server) Start() {
	go func() {
		s.log.Info("HTTP server listening", "addr", s.addr)
		if err := s.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			s.log.Error("HTTP server error", "error", err)
		}
	}()
}

func (s *Server) Shutdown(ctx context.Context) error {
	s.log.Info("shutting down HTTP server")
	return s.server.Shutdown(ctx)
}

// routes registers all HTTP handlers.
// CHANGED: wake-display route added.
func (s *Server) routes(
	otpSvc *services.OTPService,
	orderSvc *services.OrderService,
	wakeSvc *services.WakeDisplayService,
) {
	s.mux.HandleFunc("GET /health", s.handleHealth)
	s.mux.HandleFunc("POST /api/validate-code", s.validateCodeHandler(otpSvc))
	s.mux.HandleFunc("POST /api/orders/{id}/dispatch", s.dispatchHandler(orderSvc))
	s.mux.HandleFunc("POST /api/orders/{id}/wake-display", s.wakeDisplayHandler(wakeSvc)) // NEW
}

// ── Health handler ────────────────────────────────────────────────────────────

type healthResponse struct {
	Status  string `json:"status"`
	Version string `json:"version"`
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(healthResponse{
		Status:  "ok",
		Version: "2.1.0",
	})
}
