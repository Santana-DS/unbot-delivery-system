// internal/api/server.go
//
// HTTP server. Routes are registered in s.routes() which accepts both
// *services.OTPService and *services.OrderService so handlers can be
// wired without global state.
// All handler logic lives in dedicated files (validate.go, dispatch.go, etc.).
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

// NewServer constructs the server and registers all routes. Call Start() to
// begin listening. Both service dependencies are injected here so route
// registration can close over them — no package-level state.
func NewServer(
	addr string,
	log *slog.Logger,
	otpSvc *services.OTPService,
	orderSvc *services.OrderService,
) *Server {
	s := &Server{
		addr: addr,
		log:  log,
		mux:  http.NewServeMux(),
	}
	s.routes(otpSvc, orderSvc)
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

// ── Route registration ────────────────────────────────────────────────────────
// Go 1.22 method+path patterns: "POST /path" restricts to POST only.
// {id} is a wildcard segment extracted with r.PathValue("id") in the handler.

func (s *Server) routes(otpSvc *services.OTPService, orderSvc *services.OrderService) {
	s.mux.HandleFunc("GET /health", s.handleHealth)
	s.mux.HandleFunc("POST /api/validate-code", s.validateCodeHandler(otpSvc))

	// ADDED: dispatch route — closes over orderSvc.
	// Pattern uses Go 1.22 method-qualified wildcard syntax.
	s.mux.HandleFunc("POST /api/orders/{id}/dispatch", s.dispatchHandler(orderSvc))
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
		Version: "2.0.0",
	})
}
