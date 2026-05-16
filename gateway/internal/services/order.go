// internal/services/order.go
//
// CHANGES IN THIS REVISION (Phase 1.5 — On-Demand Display)
// ──────────────────────────────────────────────────────────
// REMOVED: display_qr publish from Dispatch(). Dispatch() now only issues the
//
//	OTP and publishes the navigate command. It never touches the OLED.
//
// ADDED: WakeDisplayService — owns the on-demand display trigger logic.
//
//	WakeDisplay(orderID) performs the reverse OTP lookup and publishes
//	display_qr. Called by the new POST /api/orders/{id}/wake-display handler.
//
// WHY A SEPARATE SERVICE (not a method on OrderService):
//
//	OrderService's job is order dispatch (navigate + OTP). Display management
//	is a separate concern that spans the OTP store and the MQTT publisher.
//	Keeping them separate means WakeDisplayService can be tested in isolation
//	and OrderService tests are unaffected by display logic changes.
package services

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"time"
)

// ── Gateway mode constants ────────────────────────────────────────────────────

const (
	GatewayModeFull    = "full"
	GatewayModeOTPOnly = "otp_only"
)

// ── Shared payload types ──────────────────────────────────────────────────────

type NavigatePayload struct {
	OrderID     string      `json:"order_id"`
	Destination Destination `json:"destination"`
	IssuedAt    int64       `json:"issued_at"`
}

type Destination struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}

// DisplayQRPayload is exported so wake_display.go and tests can reference it.
// The ESP32 extracts `otp` and calls qrcode_initText() to render the matrix.
type DisplayQRPayload struct {
	OrderID  string `json:"order_id"`
	OTP      string `json:"otp"`
	IssuedAt int64  `json:"issued_at"`
}

// ── DispatchResult ────────────────────────────────────────────────────────────

type DispatchResult struct {
	Success       bool   `json:"success"`
	OrderID       string `json:"order_id"`
	Status        string `json:"status"`
	OTPCode       string `json:"otp_code"`
	MQTTConnected bool   `json:"mqtt_connected"`
	GatewayMode   string `json:"gateway_mode"`
}

// ── Errors ────────────────────────────────────────────────────────────────────

var (
	ErrOTPIssuance = fmt.Errorf("failed to issue OTP for order")
	ErrWakeDisplay = fmt.Errorf("display wake command could not be delivered")
)

// =============================================================================
// OrderService — dispatch only, no display logic
// =============================================================================

type OrderService struct {
	otpSvc    *OTPService
	publisher Publisher
	log       *slog.Logger
}

func NewOrderService(otpSvc *OTPService, publisher Publisher, log *slog.Logger) *OrderService {
	return &OrderService{
		otpSvc:    otpSvc,
		publisher: publisher,
		log:       log,
	}
}

// Dispatch issues an OTP and publishes the navigate command.
// It no longer touches the OLED — display is triggered on-demand by
// WakeDisplayService when the customer taps the scanner button.
func (s *OrderService) Dispatch(orderID string, dest Destination) (*DispatchResult, error) {
	// ── Step 1: Issue OTP ─────────────────────────────────────────────────
	otpCode, err := s.otpSvc.IssueOTP(orderID)
	if err != nil {
		s.log.Error("OTP issuance failed", "order_id", orderID, "error", err)
		return nil, ErrOTPIssuance
	}
	s.log.Info("OTP issued", "order_id", orderID)
	// NOTE: OTP value intentionally not logged here in production.
	// Remove the above line and add "otp", otpCode only for local debugging.

	// ── Step 2: Publish navigate command ──────────────────────────────────
	mqttConnected := true
	gatewayMode := GatewayModeFull

	navPayload, marshalErr := json.Marshal(NavigatePayload{
		OrderID:     orderID,
		Destination: Destination{X: dest.X, Y: dest.Y},
		IssuedAt:    time.Now().Unix(),
	})
	if marshalErr != nil {
		s.log.Error("navigate payload marshal failed", "order_id", orderID, "error", marshalErr)
		mqttConnected = false
		gatewayMode = GatewayModeOTPOnly
	}

	if mqttConnected {
		if pubErr := s.publisher.Publish(TopicNavigate, navPayload); pubErr != nil {
			s.log.Warn("navigate MQTT publish failed — degrading to otp_only",
				"order_id", orderID, "error", pubErr)
			mqttConnected = false
			gatewayMode = GatewayModeOTPOnly
		} else {
			s.log.Info("navigate command published",
				"order_id", orderID,
				"topic", TopicNavigate,
				"destination_x", dest.X,
				"destination_y", dest.Y,
			)
			// display_qr is NO LONGER published here.
			// It is published lazily by WakeDisplayService.WakeDisplay()
			// when the customer initiates the scan.
		}
	}

	// ── Step 3: Return result ─────────────────────────────────────────────
	return &DispatchResult{
		Success:       true,
		OrderID:       orderID,
		Status:        gatewayMode,
		OTPCode:       otpCode,
		MQTTConnected: mqttConnected,
		GatewayMode:   gatewayMode,
	}, nil
}

// =============================================================================
// WakeDisplayService — on-demand QR display trigger
//
// Responsibilities:
//   1. Reverse-lookup the unconsumed OTP for the given orderID.
//   2. Marshal and publish DisplayQRPayload to TopicDisplayQR.
//   3. Return a typed error if the order is unknown/consumed or MQTT fails.
//
// This service is intentionally stateless beyond its two injected deps.
// Multiple concurrent WakeDisplay calls for DIFFERENT orders are safe —
// each publishes independently. Concurrent calls for the SAME order produce
// duplicate MQTT publishes (the ESP32 re-renders the same QR idempotently),
// which is safe but unlikely given the Flutter UI disables the button during
// the request.
// =============================================================================

type WakeDisplayService struct {
	otpSvc    *OTPService
	publisher Publisher
	log       *slog.Logger
}

func NewWakeDisplayService(otpSvc *OTPService, publisher Publisher, log *slog.Logger) *WakeDisplayService {
	return &WakeDisplayService{
		otpSvc:    otpSvc,
		publisher: publisher,
		log:       log,
	}
}

// WakeDisplay looks up the OTP for orderID and publishes the display_qr
// command to the ESP32.
//
// Error semantics:
//   - ErrOrderNotFound (wrapped) → HTTP 404  (order unknown or OTP consumed)
//   - ErrWakeDisplay   (wrapped) → HTTP 502  (MQTT broker unreachable)
func (s *WakeDisplayService) WakeDisplay(orderID string) error {
	// ── Step 1: Reverse lookup ────────────────────────────────────────────
	// LookupByOrderID scans under its own mutex; safe to call from any goroutine.
	otp, err := s.otpSvc.LookupByOrderID(orderID)
	if err != nil {
		// err is ErrOrderNotFound — map to 404 in the handler.
		s.log.Warn("wake-display: order not found or OTP consumed",
			"order_id", orderID, "error", err)
		return fmt.Errorf("%w: %v", ErrOrderNotFound, err)
	}

	// ── Step 2: Publish display_qr ────────────────────────────────────────
	payload, marshalErr := json.Marshal(DisplayQRPayload{
		OrderID:  orderID,
		OTP:      otp,
		IssuedAt: time.Now().Unix(),
	})
	if marshalErr != nil {
		// json.Marshal on a plain struct cannot fail in practice.
		return fmt.Errorf("%w: marshal: %v", ErrWakeDisplay, marshalErr)
	}

	if pubErr := s.publisher.Publish(TopicDisplayQR, payload); pubErr != nil {
		s.log.Error("wake-display: MQTT publish failed",
			"order_id", orderID, "error", pubErr)
		return fmt.Errorf("%w: %v", ErrWakeDisplay, pubErr)
	}

	s.log.Info("wake-display: display_qr published",
		"order_id", orderID, "topic", TopicDisplayQR)
	return nil
}
