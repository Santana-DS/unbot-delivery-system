// internal/api/dispatch.go
//
// POST /api/orders/{id}/dispatch
//
// Accepts a JSON body with {destination: {x, y}, restaurant_name}, delegates
// entirely to OrderService.Dispatch, and maps typed errors to HTTP status codes.
//
// This handler has zero business logic — it is a pure translation layer
// between HTTP and the service layer, identical in philosophy to validate.go.
//
// URL PARAMETER EXTRACTION
// ─────────────────────────
// Go 1.22's enhanced ServeMux supports path parameters natively via the
// {id} wildcard syntax. Registered in server.go as:
//
//	"POST /api/orders/{id}/dispatch"
//
// Extracted at runtime with r.PathValue("id") — no third-party router needed.
//
// IDEMPOTENCY NOTE
// ────────────────
// Dispatch is intentionally NOT idempotent at the OTP layer: re-dispatching
// the same orderID issues a new OTP (invalidating the previous one). This is
// correct — if a client retries a missed response, it gets a fresh OTP rather
// than a stale one that may have been partially consumed.
package api

import (
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strings"

	"unbot-gateway/internal/services"
)

// ── Request / Response types ──────────────────────────────────────────────────

type destinationRequest struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}

type dispatchRequest struct {
	Destination    destinationRequest `json:"destination"`
	RestaurantName string             `json:"restaurant_name"`
}

// ── Handler ───────────────────────────────────────────────────────────────────

// dispatchHandler handles POST /api/orders/{id}/dispatch.
// Registered in server.go; orderSvc injected via closure at route registration.
func (s *Server) dispatchHandler(orderSvc *services.OrderService) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// ── Method guard ──────────────────────────────────────────────────
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed,
				errorResponse{Error: "method not allowed"})
			return
		}

		// ── Extract path parameter ────────────────────────────────────────
		// Go 1.22+: r.PathValue("id") reads the {id} wildcard from the
		// mux pattern "POST /api/orders/{id}/dispatch".
		orderID := strings.TrimSpace(r.PathValue("id"))
		if orderID == "" {
			writeJSON(w, http.StatusBadRequest,
				errorResponse{Error: "order_id path parameter is required"})
			return
		}

		// ── Decode body ───────────────────────────────────────────────────
		var req dispatchRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest,
				errorResponse{Error: "malformed JSON body"})
			return
		}

		// ── Input validation ──────────────────────────────────────────────
		// json.Decoder admits NaN/Inf as float64; reject them explicitly
		// because they would silently corrupt the ROS 2 navigation goal and
		// produce undefined robot behaviour.
		if !isFiniteCoord(req.Destination.X) || !isFiniteCoord(req.Destination.Y) {
			writeJSON(w, http.StatusBadRequest,
				errorResponse{Error: "destination coordinates must be finite numbers"})
			return
		}

		// ── Delegate to service ───────────────────────────────────────────
		result, err := orderSvc.Dispatch(orderID, services.Destination{
			X: req.Destination.X,
			Y: req.Destination.Y,
		})
		if err != nil {
			switch {
			case errors.Is(err, services.ErrOTPIssuance):
				s.log.Error("OTP issuance failed in dispatch",
					"order_id", orderID,
					"error", err,
				)
				writeJSON(w, http.StatusInternalServerError,
					errorResponse{Error: "failed to generate order code; please retry"})
			default:
				s.log.Error("unexpected error in Dispatch",
					"order_id", orderID,
					"error", err,
				)
				writeJSON(w, http.StatusInternalServerError,
					errorResponse{Error: "internal server error"})
			}
			return
		}

		// ── Log and respond ───────────────────────────────────────────────
		s.log.Info("order dispatched",
			"order_id", orderID,
			"restaurant", req.RestaurantName,
			"gateway_mode", result.GatewayMode,
			"mqtt_connected", result.MQTTConnected,
		)

		writeJSON(w, http.StatusOK, result)
	}
}

// ── Helpers ───────────────────────────────────────────────────────────────────

// isFiniteCoord returns true if f is a real, finite float64.
// Rejects NaN (f != f) and ±Infinity (math.IsInf).
func isFiniteCoord(f float64) bool {
	return !math.IsNaN(f) && !math.IsInf(f, 0)
}
