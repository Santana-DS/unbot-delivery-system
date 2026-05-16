# UnBot Delivery — Engineering Conventions

## ESP32 firmware (C++ / Arduino)

### No heap allocation after `setup()`

All data structures must be stack-allocated or static. Do not call `new`, `malloc`, `String`, or any STL container that allocates on the heap after the first loop iteration. Heap fragmentation on the 520 KB SRAM will cause silent OOM failures hours into a demo.

```cpp
// CORRECT
uint8_t qrData[qrcode_getBufferSize(QR_VERSION)];  // stack
static char _pendingOrderId[64];                    // static

// WRONG
String otp = String(otpCode);   // heap allocation
std::vector<uint8_t> buf;       // heap allocation
```

### No blocking calls in `loop()`

`loop()` must return in microseconds. Never call `delay()`, `WiFi.begin()` synchronously with a wait, or any function that blocks. Use `millis()`-based timers for all deferred work. The `MqttManager` state machine is the reference pattern.

### `client.loop()` guard

Only call `_client.loop()` when `_state == CS_MQTT_CONNECTED`. Calling it in any other state reads from a stale TCP socket. The check is enforced in `_handleMqttConnected()` — do not bypass it.

### No C++ digit separators

The Arduino toolchain on ESP32 does not support C++14 digit separators (`15'000`). Write `15000`. Violations will cause a silent compile error that is hard to diagnose.

### `ConnectionState` enum prefix

All enum values carry the `CS_` prefix to avoid collision with PubSubClient preprocessor macros (`MQTT_CONNECTED`, `MQTT_DISCONNECTED`, etc.). Never add a new `ConnectionState` value without the prefix.

### MFA sequencing — `_pendingOrderId` invariant

`onUnlock()` **must** reject any unlock command where `_pendingOrderId` is empty or does not match the incoming `order_id`. This is the firmware's contribution to the MFA guarantee. Do not remove or weaken this check.

```cpp
// MANDATORY — do not remove
if (_pendingOrderId[0] == '\0') { displayMgr.showError("NO QR DISPLAYED"); return; }
if (strncmp(_pendingOrderId, orderId, sizeof(_pendingOrderId)) != 0) { displayMgr.showError("ORDER MISMATCH"); return; }
```

---

## Go gateway

### Dependency injection via constructor parameters

Services receive their dependencies through constructor functions, never via package-level globals or `init()`. This keeps tests deterministic and services independently testable.

```go
// CORRECT
otpSvc := services.NewOTPService(mqttClient)
orderSvc := services.NewOrderService(otpSvc, mqttClient, log)

// WRONG
var globalOtpSvc *services.OTPService  // ← never
```

### Handlers have zero business logic

HTTP handlers in `internal/api/` are translation layers only: decode → validate inputs → call service → map typed errors to HTTP status codes → encode. Business logic lives in `internal/services/`.

### Typed errors — no sentinel strings

Service functions return typed sentinel errors (`var ErrInvalidCode = fmt.Errorf(...)`) wrapped with `fmt.Errorf("%w: ...", ErrInvalidCode, ...)`. Handlers use `errors.Is()` to map them. Never compare `err.Error()` strings.

### OTP code consumed before MQTT publish

In `ValidateAndUnlock`, the `Consumed = true` flag is set and the mutex is released **before** calling `publisher.Publish()`. This ensures the code cannot be replayed even if the publish fails or the process crashes mid-publish.

### `sync.Mutex` — never hold across network I/O

The mutex in `OTPService` protects only the in-memory store mutation. Release it before calling `publisher.Publish()` (a network operation). Holding a mutex across I/O is a latency trap and can deadlock if the MQTT client calls back into a goroutine that tries to acquire the same lock.

### No business logic in `main.go`

`cmd/gateway/main.go` performs only: load config → construct MQTT client → construct services → construct server → start → block on signal → shutdown. No request handling, no domain logic.

---

## Flutter (Dart)

### `ValueNotifier` — always swap, never mutate

```dart
// CORRECT — listeners fire
activeOrdersNotifier.value = [...current, order];

// WRONG — listeners DO NOT fire
activeOrdersNotifier.value.add(order);  // ← NEVER
```

### UI lock (`_isValidating`) — unconditional release in `finally`

Every async chain that sets `_isValidating = true` must release it in a `finally` block. No early `return` path may skip the release — the button would be permanently disabled.

```dart
// CORRECT
Future<void> _escanearERetirar() async {
  setState(() => _isValidating = true);
  try {
    // ... async work ...
  } finally {
    if (mounted) setState(() => _isValidating = false);
  }
}
```

### Controllers — never construct in `build()`

`TextEditingController` and `AnimationController` must be created in `initState()` and disposed in `dispose()`. Constructing them inside `build()` creates a new controller on every rebuild, leaks memory, and resets cursor position.

### `removeOrder()` at non-happy-path sites must be explicit

The default `reason` parameter on `removeOrder()` is `'completed'`. Any call site that is NOT the OTP validation success path must pass `reason: 'cancelled'` explicitly. Failure produces incorrect history badges.

```dart
// Order completion (code_screen.dart)
removeOrder(widget.orderId);  // default 'completed' is correct here

// User cancellation (tracking_screen.dart)
removeOrder(order.orderId, reason: 'cancelled');  // MUST be explicit
```

### `mounted` check after every `await`

Any `setState()`, `Navigator` call, or `ScaffoldMessenger` call after an `await` must be guarded with `if (!mounted) return`. The widget may have been disposed while the async operation was in flight.

### Sealed result types — no raw status code checks

API responses are returned as sealed class hierarchies (`UnlockResult`, `WakeDisplayResult`). Use `switch` on the result type. Never check `response.statusCode` directly in widget code.

### `AC.*` context-aware color accessors — not `AppColors.*`

All widget-layer color references must use `AC.primary(context)`, `AC.card(context)`, etc. Direct `AppColors.primary` / `AppColors.card` references are hardcoded to light mode and will look broken in dark mode. `AppColors.*` is permitted only for theme-invariant values (`AppColors.accent`, `AppColors.teal`, `AppColors.statusDelivered`, etc.).

---

## MQTT topics — single source of truth

Topic strings are defined **once** in `gateway/internal/services/otp.go` (`TopicUnlock`, `TopicNavigate`, `TopicDisplayQR`) and **once** in `hardware/esp32-lock/src/main.cpp` (`TOPIC_DISPLAY_QR`, `TOPIC_UNLOCK`, `TOPIC_HEARTBEAT`). Never hardcode a topic string at a call site. If a topic changes, update both files.

---

## Credentials — never in version control

| File | Status |
|---|---|
| `gateway/.env` | `.gitignore`'d — copy from `.env.example` |
| `hardware/esp32-lock/include/secrets.h` | `.gitignore`'d — copy from `secrets.h.example` |

The `.example` files are the only credential artifacts that enter git. Production credentials are injected via environment variables (systemd `EnvironmentFile`) or NVS on the ESP32.

---

## Testing

### Go — table-driven tests with mock publisher

All service tests use the `mockPublisher` pattern from `otp_test.go`. Tests must cover:
- Happy path (success)
- Invalid input rejection
- Consumed/already-used code
- MQTT publish failure
- Concurrent access (run with `-race`)

### Flutter — no widget tests for screens with platform channels

`MobileScannerController` and camera APIs cannot be tested in a widget test environment. Test business logic (controllers, state helpers) as pure unit tests. Screen tests are manual / integration only.
