// internal/services/order.go
//
// OrderService orchestrates the full dispatch flow:
//
//  1. IssueOTP   — generate + store a 4-digit code for the order.
//  2. Publish    — send robot/commands/navigate to the ROS 2 navigation stack.
//  3. Return     — DispatchResult carrying the OTP, MQTT status, and mode.
//
// DESIGN RATIONALE
// ────────────────
// Keeping dispatch orchestration here (not in the HTTP handler) means:
//
//	a) The handler stays a pure translation layer (HTTP ↔ service errors).
//	b) The navigation MQTT publish is retryable / mockable without touching
//	   any net/http code.
//	c) When real order persistence is added (Postgres), the DB call slots in
//	   here without touching api/ at all.
//
// MQTT FAILURE POLICY (campus Wi-Fi / 4G hostile environment)
// ────────────────────────────────────────────────────────────
// If the navigate publish fails, Dispatch returns GatewayModeOTPOnly with
// MQTTConnected=false. The Flutter app renders an offline banner and the robot
// will navigate when it next reconnects — Paho's persistent session + QoS 1
// guarantees the broker delivers the retained message once the robot is online.
//
// The OTP is always issued regardless of MQTT status. This means the customer
// can always unlock the compartment once the robot physically arrives, even if
// the navigate command was delayed.
package services

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"time"
)

// ── Gateway mode constants ────────────────────────────────────────────────────
// Mirrored in Flutter's DispatchResult.gatewayMode field.

const (
	// GatewayModeFull — MQTT navigate command delivered successfully.
	GatewayModeFull = "full"

	// GatewayModeOTPOnly — MQTT publish failed; robot will navigate on
	// reconnect via broker persistence. OTP is still valid.
	GatewayModeOTPOnly = "otp_only"
)

// ── Navigate payload ──────────────────────────────────────────────────────────
// Published to robot/commands/navigate (QoS 1, non-retained).
// The ROS 2 navigation node on the Pi deserialises this and calls
// nav2's NavigateToPose action server.
//
// Coordinate system: ROS 2 map frame (metres, origin = robot home dock).
// The Flutter OrderScreen currently hardcodes destination to FT building;
// when real GPS/map integration lands, replace x/y with a named waypoint ID.

type NavigatePayload struct {
	OrderID     string      `json:"order_id"`
	Destination Destination `json:"destination"`
	IssuedAt    string      `json:"issued_at"` // RFC3339 UTC
}

type Destination struct {
	X float64 `json:"x"` // metres in map frame
	Y float64 `json:"y"` // metres in map frame
}

// ── DispatchResult ────────────────────────────────────────────────────────────
// Returned by Dispatch() and serialised directly into the HTTP 200 response
// by dispatch.go. Fields are intentionally mirrored in Flutter's DispatchResult
// model (lib/services/api_service.dart) — keep in sync.

type DispatchResult struct {
	Success       bool   `json:"success"`
	OrderID       string `json:"order_id"`
	Status        string `json:"status"` // GatewayModeFull | GatewayModeOTPOnly
	OTPCode       string `json:"otp_code"`
	MQTTConnected bool   `json:"mqtt_connected"`
	GatewayMode   string `json:"gateway_mode"` // same value as Status — redundant but Flutter expects both
}

// ── Dispatch errors ───────────────────────────────────────────────────────────

var (
	// ErrOTPIssuance — crypto/rand or store write failed. HTTP 500.
	ErrOTPIssuance = fmt.Errorf("failed to issue OTP for order")
)

// ── OrderService ──────────────────────────────────────────────────────────────

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

// Dispatch executes the full order dispatch pipeline for a given orderID and
// destination. It is safe to call from concurrent HTTP goroutines.
//
// Returns:
//   - (*DispatchResult, nil)           on full or OTP-only success.
//   - (nil, ErrOTPIssuance)            if the OTP could not be generated.
//
// The MQTT navigate publish failure is NOT a fatal error — it degrades
// gracefully to GatewayModeOTPOnly. See MQTT FAILURE POLICY above.
func (s *OrderService) Dispatch(orderID string, dest Destination) (*DispatchResult, error) {
	// ── Step 1: Issue OTP ─────────────────────────────────────────────────
	// This must succeed before we attempt any MQTT publish. If OTP issuance
	// fails (extremely unlikely — crypto/rand failure), abort entirely.
	otpCode, err := s.otpSvc.IssueOTP(orderID)
	if err != nil {
		s.log.Error("OTP issuance failed",
			"order_id", orderID,
			"error", err,
		)
		return nil, ErrOTPIssuance
	}

	s.log.Info("OTP issued",
		"order_id", orderID,
		// Do NOT log the actual OTP in production — it is a bearer secret.
		// This log line exists only to aid campus demo debugging.
		// TODO: remove before go-live.
		"otp_code", otpCode,
	)

	// ── Step 2: Publish navigate command ─────────────────────────────────
	mqttConnected := true
	gatewayMode := GatewayModeFull

	navPayload, marshalErr := json.Marshal(NavigatePayload{
		OrderID: orderID,
		Destination: Destination{
			X: dest.X,
			Y: dest.Y,
		},
		IssuedAt: time.Now().UTC().Format(time.RFC3339),
	})
	if marshalErr != nil {
		// json.Marshal on a plain struct with float64 fields cannot fail
		// unless a NaN/Inf is passed — guard anyway.
		s.log.Error("navigate payload marshal failed",
			"order_id", orderID,
			"error", marshalErr,
		)
		mqttConnected = false
		gatewayMode = GatewayModeOTPOnly
	}

	if mqttConnected {
		if pubErr := s.publisher.Publish(TopicNavigate, navPayload); pubErr != nil {
			// MQTT publish failed — degrade gracefully, do not abort.
			// The broker's persistent session will deliver the message when
			// the robot reconnects. The OTP is still valid.
			s.log.Warn("navigate MQTT publish failed — degrading to otp_only",
				"order_id", orderID,
				"error", pubErr,
			)
			mqttConnected = false
			gatewayMode = GatewayModeOTPOnly
		} else {
			s.log.Info("navigate command published",
				"order_id", orderID,
				"topic", TopicNavigate,
				"destination_x", dest.X,
				"destination_y", dest.Y,
			)
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
