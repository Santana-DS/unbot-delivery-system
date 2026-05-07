// internal/api/validate.go
//
// POST /api/validate-code
//
// Accepts a JSON body with {code, order_id}, delegates entirely to
// OTPService.ValidateAndUnlock, and maps typed service errors to HTTP
// status codes. This handler has zero business logic — it is a pure
// translation layer between HTTP and the service layer.
//
// The handler never imports internal/mqtt directly. The MQTT publish
// path is fully encapsulated behind the services.Publisher interface.
package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"unbot-gateway/internal/services"
)

// ── Request / Response types ──────────────────────────────────────────────────

type validateRequest struct {
	Code    string `json:"code"`
	OrderID string `json:"order_id"`
}

type validateResponse struct {
	Unlocked bool   `json:"unlocked"`
	OrderID  string `json:"order_id"`
}

type errorResponse struct {
	Error string `json:"error"`
}

// ── Handler ───────────────────────────────────────────────────────────────────

// ValidateHandler handles POST /api/validate-code.
// It is a method on Server so it shares the logger; it receives otpSvc via
// closure at route-registration time (see server.go: s.routes(otpSvc)).
func (s *Server) validateCodeHandler(otpSvc *services.OTPService) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// ── Method guard ──────────────────────────────────────────────────
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, errorResponse{Error: "method not allowed"})
			return
		}

		// ── Decode ────────────────────────────────────────────────────────
		var req validateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse{Error: "malformed JSON body"})
			return
		}

		// ── Input validation ──────────────────────────────────────────────
		// We validate length and digit-only here so the service layer never
		// has to deal with obviously invalid input.
		if len(req.Code) != 4 {
			writeJSON(w, http.StatusBadRequest, errorResponse{Error: "code must be exactly 4 digits"})
			return
		}
		for _, ch := range req.Code {
			if ch < '0' || ch > '9' {
				writeJSON(w, http.StatusBadRequest, errorResponse{Error: "code must contain digits only"})
				return
			}
		}
		if req.OrderID == "" {
			writeJSON(w, http.StatusBadRequest, errorResponse{Error: "order_id is required"})
			return
		}

		// ── Delegate to service ───────────────────────────────────────────
		err := otpSvc.ValidateAndUnlock(req.Code, req.OrderID)
		if err == nil {
			s.log.Info("unlock command published",
				"order_id", req.OrderID,
				"code", req.Code,
			)
			writeJSON(w, http.StatusOK, validateResponse{
				Unlocked: true,
				OrderID:  req.OrderID,
			})
			return
		}

		// ── Error mapping ─────────────────────────────────────────────────
		switch {
		case errors.Is(err, services.ErrInvalidCode),
			errors.Is(err, services.ErrConsumed):
			// Both map to 401 with the same user-facing message so we don't
			// leak whether a code exists but is consumed (enumeration risk).
			s.log.Warn("OTP validation failed",
				"order_id", req.OrderID,
				"reason", err.Error(),
			)
			writeJSON(w, http.StatusUnauthorized, errorResponse{Error: "invalid or expired code"})

		case errors.Is(err, services.ErrPublish):
			// The code was consumed but the robot didn't receive the command.
			// 502 signals to the app that it must not show "compartment opened".
			s.log.Error("MQTT publish failed after OTP validation",
				"order_id", req.OrderID,
				"error", err.Error(),
			)
			writeJSON(w, http.StatusBadGateway, errorResponse{Error: "robot is unreachable; please try again"})

		default:
			s.log.Error("unexpected error in ValidateAndUnlock",
				"order_id", req.OrderID,
				"error", err.Error(),
			)
			writeJSON(w, http.StatusInternalServerError, errorResponse{Error: "internal server error"})
		}
	}
}

// ── JSON helper ───────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
