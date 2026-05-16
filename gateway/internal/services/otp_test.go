// internal/services/otp_test.go
//
// Tests for OTPService. The mock publisher lets us exercise every code path
// — including MQTT failure — without a real broker.
package services

import (
	"errors"
	"sync"
	"testing"
)

// ── Mock publisher ────────────────────────────────────────────────────────────

type mockPublisher struct {
	mu       sync.Mutex
	calls    []mockCall
	failNext bool // if true, next Publish returns an error
}

type mockCall struct {
	topic   string
	payload []byte
}

func (m *mockPublisher) Publish(topic string, payload []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.failNext {
		m.failNext = false
		return errors.New("broker unreachable")
	}
	m.calls = append(m.calls, mockCall{topic: topic, payload: payload})
	return nil
}

func (m *mockPublisher) callCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.calls)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

func TestValidateAndUnlock_Success(t *testing.T) {
	pub := &mockPublisher{}
	svc := NewOTPService(pub)

	err := svc.ValidateAndUnlock("1234", "order_mock_001")
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if pub.callCount() != 1 {
		t.Fatalf("expected 1 MQTT publish, got %d", pub.callCount())
	}
	if pub.calls[0].topic != TopicUnlock {
		t.Errorf("expected topic %q, got %q", TopicUnlock, pub.calls[0].topic)
	}
}

func TestValidateAndUnlock_InvalidCode(t *testing.T) {
	pub := &mockPublisher{}
	svc := NewOTPService(pub)

	err := svc.ValidateAndUnlock("9999", "order_mock_001")
	if !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("expected ErrInvalidCode, got: %v", err)
	}
	if pub.callCount() != 0 {
		t.Error("MQTT must not be called on invalid code")
	}
}

func TestValidateAndUnlock_ConsumedCode(t *testing.T) {
	pub := &mockPublisher{}
	svc := NewOTPService(pub)

	// First use — must succeed.
	if err := svc.ValidateAndUnlock("5678", "order_mock_002"); err != nil {
		t.Fatalf("first use failed unexpectedly: %v", err)
	}
	// Second use — must be rejected.
	err := svc.ValidateAndUnlock("5678", "order_mock_002")
	if !errors.Is(err, ErrConsumed) {
		t.Fatalf("expected ErrConsumed on second use, got: %v", err)
	}
	if pub.callCount() != 1 {
		t.Errorf("MQTT must be called exactly once, got %d", pub.callCount())
	}
}

func TestValidateAndUnlock_PublishFailure(t *testing.T) {
	pub := &mockPublisher{failNext: true}
	svc := NewOTPService(pub)

	err := svc.ValidateAndUnlock("0000", "order_mock_003")
	if !errors.Is(err, ErrPublish) {
		t.Fatalf("expected ErrPublish, got: %v", err)
	}

	// Code must be consumed even after a publish failure — no replay allowed.
	err2 := svc.ValidateAndUnlock("0000", "order_mock_003")
	if !errors.Is(err2, ErrConsumed) {
		t.Fatalf("expected ErrConsumed after failed publish, got: %v", err2)
	}
}

func TestValidateAndUnlock_ConcurrentSingleUse(t *testing.T) {
	// Fire 50 goroutines all trying to consume the same code simultaneously.
	// Exactly one must succeed; the rest must get ErrConsumed.
	pub := &mockPublisher{}
	svc := NewOTPService(pub)

	const goroutines = 50
	results := make([]error, goroutines)
	var wg sync.WaitGroup
	wg.Add(goroutines)

	for i := 0; i < goroutines; i++ {
		i := i
		go func() {
			defer wg.Done()
			results[i] = svc.ValidateAndUnlock("1234", "order_mock_001")
		}()
	}
	wg.Wait()

	successes := 0
	for _, err := range results {
		if err == nil {
			successes++
		}
	}
	if successes != 1 {
		t.Errorf("expected exactly 1 success under concurrency, got %d", successes)
	}
	if pub.callCount() != 1 {
		t.Errorf("expected exactly 1 MQTT publish, got %d", pub.callCount())
	}
}
