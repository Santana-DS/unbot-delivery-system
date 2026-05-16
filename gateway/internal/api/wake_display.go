// internal/api/wake_display.go
//
// POST /api/orders/{id}/wake-display
//
// Triggers the ESP32 to render the QR Code for the given order on its OLED.
// Called by the Flutter app immediately before opening the QR scanner screen.
//
// RESPONSIBILITY BOUNDARY:
//
//	This handler is a pure HTTP↔service translation layer, identical in
//	philosophy to validate.go and dispatch.go. Zero business logic lives here.
//
// IDEMPOTENCY:
//
//	Safe to call multiple times for the same order. Each call re-publishes
//	the same display_qr payload — the ESP32 re-renders the same QR (idempotent
//	display operation). The OTP is NOT consumed by this endpoint; only
//	POST /api/validate-code consumes it.
//
// SEQUENCING CONTRACT (enforced by firmware, not here):
//
//	The ESP32 stores the pending order_id from display_qr and cross-validates
//	it against the incoming unlock command. This handler does not need to
//	enforce sequencing — that invariant lives in firmware onUnlock().
//
// ERROR MAPPING:
//
//	ErrOrderNotFound → 404  (order never dispatched, or OTP already consumed)
//	ErrWakeDisplay   → 502  (MQTT broker unreachable)
//	default          → 500
package api

import (
	"errors"
	"net/http"
	"strings"

	"unbot-gateway/internal/services"
)

// wakeDisplayHandler handles POST /api/orders/{id}/wake-display.
// wakeSvc is injected via closure at route registration in server.go.
func (s *Server) wakeDisplayHandler(wakeSvc *services.WakeDisplayService) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// ── Method guard ──────────────────────────────────────────────────
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed,
				errorResponse{Error: "method not allowed"})
			return
		}

		// ── Extract path parameter ────────────────────────────────────────
		// Go 1.22 ServeMux pattern: "POST /api/orders/{id}/wake-display"
		orderID := strings.TrimSpace(r.PathValue("id"))
		if orderID == "" {
			writeJSON(w, http.StatusBadRequest,
				errorResponse{Error: "order_id path parameter is required"})
			return
		}

		// ── Delegate to service ───────────────────────────────────────────
		err := wakeSvc.WakeDisplay(orderID)
		if err == nil {
			s.log.Info("display_qr triggered via wake-display endpoint",
				"order_id", orderID)
			writeJSON(w, http.StatusOK, map[string]any{
				"triggered": true,
				"order_id":  orderID,
			})
			return
		}

		// ── Error mapping ─────────────────────────────────────────────────
		switch {
		case errors.Is(err, services.ErrOrderNotFound):
			// Order was never dispatched, or the OTP was already consumed
			// (customer already completed pickup). Flutter should handle this
			// by redirecting to the manual OTP entry screen.
			s.log.Warn("wake-display: order not found",
				"order_id", orderID, "error", err)
			writeJSON(w, http.StatusNotFound,
				errorResponse{Error: "order not found or delivery already completed"})

		case errors.Is(err, services.ErrWakeDisplay):
			// MQTT broker unreachable. Flutter should surface a retry option
			// or fall back to manual OTP entry (which doesn't need the OLED).
			s.log.Error("wake-display: MQTT publish failed",
				"order_id", orderID, "error", err)
			writeJSON(w, http.StatusBadGateway,
				errorResponse{Error: "robot display is unreachable; use manual code entry"})

		default:
			s.log.Error("wake-display: unexpected error",
				"order_id", orderID, "error", err)
			writeJSON(w, http.StatusInternalServerError,
				errorResponse{Error: "internal server error"})
		}
	}
}
