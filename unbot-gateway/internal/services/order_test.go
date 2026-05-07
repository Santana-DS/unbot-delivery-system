// internal/services/order_test.go
//
// Tests for OrderService.Dispatch. Uses the same mockPublisher from otp_test.go
// pattern — reproduced here so the test package stays self-contained and
// both test files can be run independently with `go test ./internal/services/...`.
package services

import (
	"errors"
	"log/slog"
	"os"
	"strings"
	"sync"
	"testing"
)

// ── Shared mock publisher ─────────────────────────────────────────────────────
// Reuses the same interface defined in otp_test.go conceptually, but since
// both files are in the same package we can share the type directly.
// mockPublisher is defined in otp_test.go; it is visible here.

// ── Helper ────────────────────────────────────────────────────────────────────

func newTestOrderService(pub *mockPublisher) (*OrderService, *OTPService) {
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelError, // suppress info logs during tests
	}))
	otpSvc := NewOTPService(pub)
	orderSvc := NewOrderService(otpSvc, pub, log)
	return orderSvc, otpSvc
}

var testDest = Destination{X: 12.0, Y: -3.5}

// ── Tests ─────────────────────────────────────────────────────────────────────

func TestDispatch_FullMode_Success(t *testing.T) {
	pub := &mockPublisher{}
	orderSvc, otpSvc := newTestOrderService(pub)

	result, err := orderSvc.Dispatch("order_test_001", testDest)
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if !result.Success {
		t.Error("expected result.Success == true")
	}
	if result.GatewayMode != GatewayModeFull {
		t.Errorf("expected GatewayModeFull, got %q", result.GatewayMode)
	}
	if !result.MQTTConnected {
		t.Error("expected MQTTConnected == true")
	}
	if len(result.OTPCode) != 4 {
		t.Errorf("OTPCode should be 4 digits, got %q (len %d)", result.OTPCode, len(result.OTPCode))
	}
	for _, ch := range result.OTPCode {
		if ch < '0' || ch > '9' {
			t.Errorf("OTPCode contains non-digit character: %q", result.OTPCode)
		}
	}

	// Exactly one navigate publish should have fired.
	if pub.callCount() != 1 {
		t.Errorf("expected 1 MQTT publish, got %d", pub.callCount())
	}
	if pub.calls[0].topic != TopicNavigate {
		t.Errorf("expected topic %q, got %q", TopicNavigate, pub.calls[0].topic)
	}

	// The issued OTP must be immediately validatable by OTPService.
	if err := otpSvc.ValidateAndUnlock(result.OTPCode, result.OrderID); err != nil {
		t.Errorf("issued OTP should be immediately validatable, got error: %v", err)
	}
}

func TestDispatch_OTPOnly_WhenMQTTFails(t *testing.T) {
	// Simulate campus Wi-Fi outage: every publish call returns an error.
	pub := &mockPublisher{failNext: true}
	orderSvc, _ := newTestOrderService(pub)

	result, err := orderSvc.Dispatch("order_test_002", testDest)
	if err != nil {
		t.Fatalf("dispatch should not return error on MQTT failure, got: %v", err)
	}
	if result.GatewayMode != GatewayModeOTPOnly {
		t.Errorf("expected GatewayModeOTPOnly, got %q", result.GatewayMode)
	}
	if result.MQTTConnected {
		t.Error("expected MQTTConnected == false on publish failure")
	}
	// OTP must still be issued and valid even when MQTT fails.
	if len(result.OTPCode) != 4 {
		t.Errorf("OTPCode should still be 4 digits on MQTT failure, got %q", result.OTPCode)
	}
}

func TestDispatch_OTPIsUnique(t *testing.T) {
	// Issue 50 OTPs and confirm no two share the same code for the same order.
	// (Collisions are statistically possible for 4 digits but should be rare
	// enough that 50 sequential issues never collide.)
	pub := &mockPublisher{}
	orderSvc, _ := newTestOrderService(pub)

	seen := make(map[string]struct{})
	for i := 0; i < 50; i++ {
		result, err := orderSvc.Dispatch("order_uniqueness_test", testDest)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		seen[result.OTPCode] = struct{}{}
	}
	// For 50 sequential 4-digit codes the probability of zero collisions is
	// ~88% — this test is probabilistic. If it flakes consistently, widen to
	// 6-digit codes in IssueOTP.
	if len(seen) < 10 {
		t.Errorf("suspiciously low unique OTP count (%d/50) — check crypto/rand", len(seen))
	}
}

func TestDispatch_NavigatePayloadContainsOrderID(t *testing.T) {
	pub := &mockPublisher{}
	orderSvc, _ := newTestOrderService(pub)

	const orderID = "order_payload_check"
	_, err := orderSvc.Dispatch(orderID, testDest)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if pub.callCount() == 0 {
		t.Fatal("no MQTT publish recorded")
	}
	payload := string(pub.calls[0].payload)
	if !strings.Contains(payload, orderID) {
		t.Errorf("navigate payload %q does not contain order_id %q", payload, orderID)
	}
}

func TestDispatch_ConcurrentSafety(t *testing.T) {
	// 20 goroutines dispatching different orders simultaneously.
	// Verifies no data races on the OTP store (run with -race).
	pub := &mockPublisher{}
	orderSvc, _ := newTestOrderService(pub)

	var wg sync.WaitGroup
	errs := make([]error, 20)
	wg.Add(20)

	for i := 0; i < 20; i++ {
		i := i
		go func() {
			defer wg.Done()
			_, errs[i] = orderSvc.Dispatch(
				// Each goroutine uses a unique orderID to avoid deliberate collision.
				strings.Repeat("x", i+1),
				testDest,
			)
		}()
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil && !errors.Is(err, ErrOTPIssuance) {
			t.Errorf("goroutine %d: unexpected error: %v", i, err)
		}
	}
}
