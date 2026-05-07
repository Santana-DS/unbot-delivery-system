// internal/api/server.go
//
// HTTP server. Routes are registered in s.routes() which now accepts
// *services.OTPService so handlers can be wired without global state.
// All handler logic lives in dedicated files (validate.go, etc.).
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

// NewServer constructs the server. Call Start() to begin listening.
// otpSvc is injected here so route registration can close over it.
func NewServer(addr string, log *slog.Logger, otpSvc *services.OTPService) *Server {
	s := &Server{
		addr: addr,
		log:  log,
		mux:  http.NewServeMux(),
	}
	s.routes(otpSvc)
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

func (s *Server) routes(otpSvc *services.OTPService) {
	s.mux.HandleFunc("/health", s.handleHealth)
	s.mux.HandleFunc("/api/validate-code", s.validateCodeHandler(otpSvc))
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
