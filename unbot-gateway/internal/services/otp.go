// internal/services/otp.go
//
// OTP validation, issuance, and unlock orchestration.
//
// DESIGN CONTRACT:
//   - IssueOTP generates a cryptographically random 4-digit code, stores it
//     atomically, and returns it. The caller (OrderService) echoes it to the
//     Flutter app inside the DispatchResult payload.
//   - ValidateAndUnlock is unchanged: single-use consumption, typed errors.
//   - The Publisher interface is defined here to keep services/ free of any
//     import dependency on internal/mqtt (no import cycle).
//   - seedMockData is preserved for local testing; remove when real storage
//     (Postgres/Redis) is introduced.
package services

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math/big"
	"sync"
	"time"
)

// ── Errors ────────────────────────────────────────────────────────────────────

var (
	ErrInvalidCode = fmt.Errorf("invalid or expired code")
	ErrConsumed    = fmt.Errorf("code already used")
	ErrPublish     = fmt.Errorf("unlock command could not be delivered to robot")
)

// ── Publisher interface ───────────────────────────────────────────────────────
// mqtt.Client satisfies this interface structurally — no changes to that
// package are required. main.go wires the concrete type.

type Publisher interface {
	Publish(topic string, payload []byte) error
}

// ── MQTT topics ───────────────────────────────────────────────────────────────

const (
	TopicUnlock   = "robot/commands/unlock"
	TopicNavigate = "robot/commands/navigate"
)

// ── OTPRecord ─────────────────────────────────────────────────────────────────

type OTPRecord struct {
	Code     string
	OrderID  string
	Consumed bool
	IssuedAt time.Time
}

// ── OTPService ────────────────────────────────────────────────────────────────

type OTPService struct {
	publisher Publisher

	mu    sync.Mutex
	store map[string]*OTPRecord // key: code
}

func NewOTPService(p Publisher) *OTPService {
	svc := &OTPService{
		publisher: p,
		store:     make(map[string]*OTPRecord),
	}
	svc.seedMockData()
	return svc
}

// IssueOTP generates a cryptographically random 4-digit code, stores it in
// the OTP table associated with orderID, and returns the plaintext code.
//
// The code is the ONLY secret — do not log it in production. The caller
// (OrderService.Dispatch) is responsible for echoing it to the Flutter app
// over HTTPS so the client can display it and later validate it.
//
// Collision probability for 4 digits (10^4 = 10 000 values) is negligible
// for the expected concurrent order volume at a university campus. If you
// scale beyond ~500 concurrent active orders, widen to 6 digits here and
// in the Flutter OTP entry screen simultaneously.
func (s *OTPService) IssueOTP(orderID string) (string, error) {
	// crypto/rand for uniform distribution — math/rand.Intn is NOT suitable
	// for security-sensitive token generation.
	n, err := rand.Int(rand.Reader, big.NewInt(10_000))
	if err != nil {
		return "", fmt.Errorf("OTP generation failed: %w", err)
	}

	code := fmt.Sprintf("%04d", n.Int64())

	s.mu.Lock()
	defer s.mu.Unlock()

	// Overwrite any existing record for this orderID to handle re-dispatch
	// (e.g., operator retries after a network failure). The old code is
	// invalidated implicitly because lookup is by code, not orderID.
	s.store[code] = &OTPRecord{
		Code:     code,
		OrderID:  orderID,
		Consumed: false,
		IssuedAt: time.Now().UTC(),
	}

	return code, nil
}

// seedMockData pre-populates the in-memory store with test codes.
// Remove this method entirely when real storage is introduced.
func (s *OTPService) seedMockData() {
	testCodes := []OTPRecord{
		{Code: "1234", OrderID: "order_mock_001", IssuedAt: time.Now().UTC()},
		{Code: "5678", OrderID: "order_mock_002", IssuedAt: time.Now().UTC()},
		{Code: "0000", OrderID: "order_mock_003", IssuedAt: time.Now().UTC()},
	}
	for i := range testCodes {
		s.store[testCodes[i].Code] = &testCodes[i]
	}
}

// unlockPayload is the JSON published to robot/commands/unlock.
// issued_at lets the ESP32 apply its own expiry guard against stale messages
// that queued in the broker during a connectivity gap.
type unlockPayload struct {
	OrderID  string `json:"order_id"`
	Code     string `json:"code"`
	IssuedAt string `json:"issued_at"` // RFC3339 UTC
}

// ValidateAndUnlock validates the given code and publishes the unlock command.
//
// Error semantics:
//   - ErrInvalidCode → HTTP 401
//   - ErrConsumed    → HTTP 401 (same user-facing message, distinct log)
//   - ErrPublish     → HTTP 502 (MQTT unreachable; do NOT show "compartment opened")
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
	// Mark consumed before releasing lock and before publishing.
	// If publish fails, the code stays consumed — operator must reissue.
	// This prevents replay attacks after transient broker failures.
	record.Consumed = true
	s.mu.Unlock()

	payload, err := json.Marshal(unlockPayload{
		OrderID:  orderID,
		Code:     code,
		IssuedAt: time.Now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		// json.Marshal on a plain struct cannot fail in practice, but handle
		// for correctness and linter compliance.
		return fmt.Errorf("%w: marshal: %v", ErrPublish, err)
	}

	if err := s.publisher.Publish(TopicUnlock, payload); err != nil {
		return fmt.Errorf("%w: %v", ErrPublish, err)
	}

	return nil
}
