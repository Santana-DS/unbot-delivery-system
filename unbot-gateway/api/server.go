// internal/api/server.go
//
// HTTP server scaffold. Currently exposes only /health so the cloud VM's
// load balancer and the Flutter splash screen can probe gateway liveness.
//
// Subsequent tickets wire OTP and dispatch routes here by registering
// handlers on the shared *http.ServeMux. The server is intentionally
// stdlib-only — no framework dependency until routing complexity justifies one.
package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"
)

// Server owns the HTTP listener lifecycle.
type Server struct {
	addr   string
	log    *slog.Logger
	mux    *http.ServeMux
	server *http.Server
}

// NewServer constructs the server and registers all routes.
func NewServer(addr string, log *slog.Logger) *Server {
	s := &Server{
		addr: addr,
		log:  log,
		mux:  http.NewServeMux(),
	}
	s.routes()
	s.server = &http.Server{
		Addr:         addr,
		Handler:      s.mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}
	return s
}

// Start begins listening in a goroutine. Non-blocking.
func (s *Server) Start() {
	go func() {
		s.log.Info("HTTP server listening", "addr", s.addr)
		if err := s.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			s.log.Error("HTTP server error", "error", err)
		}
	}()
}

// Shutdown gracefully drains connections. Called from main's shutdown hook.
func (s *Server) Shutdown(ctx context.Context) error {
	s.log.Info("shutting down HTTP server")
	return s.server.Shutdown(ctx)
}

// ── Route registration ────────────────────────────────────────────────────────

func (s *Server) routes() {
	s.mux.HandleFunc("/health", s.handleHealth)
	// TODO: s.mux.HandleFunc("/api/orders/{id}/dispatch", s.handleDispatch)
	// TODO: s.mux.HandleFunc("/api/validate-code",        s.handleValidateOTP)
}

// ── Handlers ──────────────────────────────────────────────────────────────────

type healthResponse struct {
	Status  string `json:"status"`
	Version string `json:"version"`
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(healthResponse{
		Status:  "ok",
		Version: "2.0.0-boilerplate",
	})
}
