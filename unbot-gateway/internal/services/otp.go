// internal/services/otp.go
//
// OTP validation and unlock orchestration.
//
// DESIGN CONTRACT (enforced now, even though storage is mocked):
//   - ValidateAndUnlock returns a typed error so callers distinguish
//     "bad code" (401) from "broker down" (502) without string matching.
//   - The Publisher interface is defined here so the services layer has
//     zero import dependency on internal/mqtt. main.go wires the concrete
//     implementation via dependency injection.
//   - The mock store simulates single-use consumption: a code transitions
//     from "valid" → "consumed" on first successful validation. Calling
//     ValidateAndUnlock a second time with the same code returns ErrConsumed.
//     This contract must survive intact when real storage is wired in.
package services

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"
)

// ── Errors ────────────────────────────────────────────────────────────────────
// Typed sentinel errors let HTTP handlers map outcomes to status codes
// without string matching or type assertions on generic errors.

var (
	ErrInvalidCode = fmt.Errorf("invalid or expired code")
	ErrConsumed    = fmt.Errorf("code already used")
	ErrPublish     = fmt.Errorf("unlock command could not be delivered to robot")
)

// ── Publisher interface ───────────────────────────────────────────────────────
// Defined in services so this package has no import cycle with internal/mqtt.
// mqtt.Client satisfies this interface structurally (duck typing) — no changes
// to that package are required.

type Publisher interface {
	Publish(topic string, payload []byte) error
}

// ── MQTT topic ────────────────────────────────────────────────────────────────

const TopicUnlock = "robot/commands/unlock"

// ── OTPRecord ─────────────────────────────────────────────────────────────────
// Represents a single issuable OTP. In production this lives in a database row.

type OTPRecord struct {
	Code     string
	OrderID  string
	Consumed bool
}

// ── OTPService ────────────────────────────────────────────────────────────────

type OTPService struct {
	publisher Publisher

	// mu guards store. All access must go through the exported methods.
	// When real storage (Postgres, Redis) replaces the map, remove mu entirely
	// and let the DB driver handle its own concurrency — don't wrap it here.
	mu    sync.Mutex
	store map[string]*OTPRecord // key: code
}

// NewOTPService wires the publisher and seeds the mock store.
// Replace the seed call with a real DB client in the production iteration.
func NewOTPService(p Publisher) *OTPService {
	svc := &OTPService{
		publisher: p,
		store:     make(map[string]*OTPRecord),
	}
	svc.seedMockData()
	return svc
}

// seedMockData pre-populates the in-memory store with test codes.
// Remove this method entirely when real storage is introduced.
func (s *OTPService) seedMockData() {
	testCodes := []OTPRecord{
		{Code: "1234", OrderID: "order_mock_001"},
		{Code: "5678", OrderID: "order_mock_002"},
		{Code: "0000", OrderID: "order_mock_003"},
	}
	for i := range testCodes {
		s.store[testCodes[i].Code] = &testCodes[i]
	}
}

// unlockPayload is the JSON structure published to the MQTT unlock topic.
// issued_at lets the robot apply its own expiry guard against stale messages
// that sat in the broker queue during a connectivity gap.
type unlockPayload struct {
	OrderID  string `json:"order_id"`
	Code     string `json:"code"`
	IssuedAt string `json:"issued_at"` // RFC3339 UTC
}

// ValidateAndUnlock validates the given code against the store and, on success,
// publishes an unlock command to the robot via MQTT.
//
// Error semantics (callers must not match on error strings):
//   - ErrInvalidCode → HTTP 401
//   - ErrConsumed    → HTTP 401 (same user-facing message, distinct log)
//   - ErrPublish     → HTTP 502 (robot unreachable; do not tell user "opened")
func (s *OTPService) ValidateAndUnlock(code, orderID string) error {
	s.mu.Lock()
	record, exists := s.store[code]
	if !exists {
		s.mu.Unlock()
		return ErrInvalidCode
	}
	if record.Consumed {
		s.mu.Unlock()
		return ErrConsumed
	}
	// Mark consumed before releasing the lock and before publishing.
	// If the publish fails we return ErrPublish but the code remains consumed —
	// this is intentional: the operator must reissue a new OTP rather than
	// allow a replay of the same code after a transient broker failure.
	record.Consumed = true
	s.mu.Unlock()

	payload, err := json.Marshal(unlockPayload{
		OrderID:  orderID,
		Code:     code,
		IssuedAt: time.Now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		// json.Marshal on a plain struct with string fields cannot fail in
		// practice, but we handle it to satisfy the linter and for safety.
		return fmt.Errorf("%w: marshal: %v", ErrPublish, err)
	}

	if err := s.publisher.Publish(TopicUnlock, payload); err != nil {
		return fmt.Errorf("%w: %v", ErrPublish, err)
	}

	return nil
}
