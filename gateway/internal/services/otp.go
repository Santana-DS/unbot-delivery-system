// internal/services/otp.go
//
// CHANGES IN THIS REVISION (Phase 1.5 — On-Demand Display)
// ──────────────────────────────────────────────────────────
//
//   - LookupByOrderID(orderID) — reverse lookup needed by WakeDisplayService
//     so the wake-display handler can retrieve the OTP for an already-dispatched
//     order without touching the validate/consume path.
//
//   - TopicDisplayQR constant moved here from order.go so all MQTT topic strings
//     live in a single file.
//
// STORE KEY DESIGN NOTE:
//
//	The store is keyed by `code` (not orderID) because ValidateAndUnlock
//	receives a code from the user and must look it up in O(1). LookupByOrderID
//	does a linear scan — acceptable because:
//	  a) The store is bounded: university campus concurrency is O(10s) of orders.
//	  b) The scan is read-only under the mutex; no write contention.
//	  c) Adding a second map[orderID]code would require dual writes on IssueOTP
//	     and dual deletes on any future eviction — not worth it for this scale.
//	If you ever need O(1) reverse lookup, add the second map then.
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
	ErrInvalidCode   = fmt.Errorf("invalid or expired code")
	ErrConsumed      = fmt.Errorf("code already used")
	ErrPublish       = fmt.Errorf("unlock command could not be delivered to robot")
	ErrOrderNotFound = fmt.Errorf("order not found or OTP already consumed")
)

// ── Publisher interface ───────────────────────────────────────────────────────

type Publisher interface {
	Publish(topic string, payload []byte) error
}

// ── MQTT topic constants ──────────────────────────────────────────────────────
// Single source of truth. All handlers reference these; never hardcode strings.

const (
	TopicUnlock    = "robot/commands/unlock"
	TopicNavigate  = "robot/commands/navigate"
	TopicDisplayQR = "robot/commands/display_qr" // MOVED here from order.go
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

// IssueOTP generates a cryptographically random 4-digit code, stores it
// associated with orderID, and returns the plaintext code.
func (s *OTPService) IssueOTP(orderID string) (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(10_000))
	if err != nil {
		return "", fmt.Errorf("OTP generation failed: %w", err)
	}

	code := fmt.Sprintf("%04d", n.Int64())

	s.mu.Lock()
	defer s.mu.Unlock()

	s.store[code] = &OTPRecord{
		Code:     code,
		OrderID:  orderID,
		Consumed: false,
		IssuedAt: time.Now().UTC(),
	}

	return code, nil
}

// LookupByOrderID returns the active (unconsumed) OTP code for the given
// orderID. Returns ErrOrderNotFound if no unconsumed record exists.
//
// THREAD SAFETY: acquires mu for the duration of the scan.
// CALLED BY: WakeDisplayService.WakeDisplay only.
// NOT called by ValidateAndUnlock — that path looks up by code directly.
func (s *OTPService) LookupByOrderID(orderID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	for _, rec := range s.store {
		if rec.OrderID == orderID && !rec.Consumed {
			return rec.Code, nil
		}
	}
	return "", ErrOrderNotFound
}

// seedMockData pre-populates the in-memory store with known test codes.
// Remove when real persistent storage is introduced.
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
type unlockPayload struct {
	OrderID  string `json:"order_id"`
	Code     string `json:"code"`
	IssuedAt int64  `json:"issued_at"`
}

// ValidateAndUnlock validates code, marks it consumed, publishes unlock.
// Unchanged from Phase 1.
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
	record.Consumed = true
	s.mu.Unlock()

	payload, err := json.Marshal(unlockPayload{
		OrderID:  orderID,
		Code:     code,
		IssuedAt: time.Now().Unix(),
	})
	if err != nil {
		return fmt.Errorf("%w: marshal: %v", ErrPublish, err)
	}

	if err := s.publisher.Publish(TopicUnlock, payload); err != nil {
		return fmt.Errorf("%w: %v", ErrPublish, err)
	}

	return nil
}
