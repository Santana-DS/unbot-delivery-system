# UnBot Delivery — Protocol Contracts

## REST API (Go gateway · `HTTP :8080`)

Base URL (dev tunnel): `https://rvdj88q6-8000.brs.devtunnels.ms`  
Override at Flutter build time: `--dart-define=API_BASE_URL=http://10.0.2.2:8080`

All request/response bodies are `application/json`. All error responses share the shape `{"error": "<message>"}`.

---

### `GET /health`

Health probe. No auth required.

**Response 200**
```json
{ "status": "ok", "version": "2.1.0" }
```

---

### `POST /api/orders/{id}/dispatch`

Orchestrates a delivery. Issues a cryptographically random 4-digit OTP and publishes a navigate command to ROS 2 via MQTT.

**Path parameter**: `id` — caller-generated order ID (e.g. `order_1714000000123`).

**Request body**
```json
{
  "destination": { "x": 12.0, "y": -3.5 },
  "restaurant_name": "Marmitas da Vó"
}
```

Coordinate validation: `x` and `y` must be finite floats (NaN and ±Inf are rejected with 400).

**Response 200** — MQTT reachable (full mode)
```json
{
  "success": true,
  "order_id": "order_1714000000123",
  "status": "full",
  "otp_code": "7429",
  "mqtt_connected": true,
  "gateway_mode": "full"
}
```

**Response 200** — MQTT unreachable (degraded mode)
```json
{
  "success": true,
  "order_id": "order_1714000000123",
  "status": "otp_only",
  "otp_code": "7429",
  "mqtt_connected": false,
  "gateway_mode": "otp_only"
}
```

OTP is always issued regardless of MQTT status. `otp_only` orders are displayed with a Wi-Fi-off badge in the Flutter UI.

**Response 500** — OTP issuance failed (crypto/rand failure — should never happen).

---

### `POST /api/orders/{id}/wake-display`

Triggers the ESP32 OLED to render the QR Code for an already-dispatched order. Called by Flutter immediately before opening `QrScannerScreen`. Idempotent — multiple calls re-render the same QR.

**Path parameter**: `id` — the order ID from the dispatch response.

**Request body**: empty (order ID is in the path; no additional parameters).

**Response 200**
```json
{ "triggered": true, "order_id": "order_1714000000123" }
```

**Response 404** — order not found or OTP already consumed.
```json
{ "error": "order not found or delivery already completed" }
```
Flutter should skip the scanner and offer manual OTP entry.

**Response 502** — MQTT broker unreachable.
```json
{ "error": "robot display is unreachable; use manual code entry" }
```
Flutter must offer manual OTP entry as fallback; must not block the user.

---

### `POST /api/validate-code`

Validates a 4-digit OTP and, on success, publishes an unlock command to the ESP32 solenoid via MQTT. Codes are single-use; concurrent validation requests for the same code are serialised under `sync.Mutex`.

**Request body**
```json
{ "code": "7429", "order_id": "order_1714000000123" }
```

Validation: `code` must be exactly 4 ASCII digit characters. `order_id` must be non-empty.

**Response 200** — unlock command delivered
```json
{ "unlocked": true, "order_id": "order_1714000000123" }
```

**Response 401** — code invalid or already consumed
```json
{ "error": "invalid or expired code" }
```
Both `ErrInvalidCode` and `ErrConsumed` map to 401 (no enumeration leakage).

**Response 502** — code consumed but MQTT publish failed
```json
{ "error": "robot is unreachable; please try again" }
```
The code is consumed even on publish failure. The customer must contact support; no replay is possible.

---

## MQTT topics

Broker: `tcp://<EC2_IP>:1883` · Authentication: M2M credentials (configured via `setup_mosquitto.sh`) · No anonymous access.

| Topic | Direction | QoS | Publisher | Subscriber(s) |
|---|---|---|---|---|
| `robot/commands/navigate` | cloud → robot | 1 | Go gateway | Raspberry Pi (ROS 2) |
| `robot/commands/display_qr` | cloud → robot | 1 | Go gateway | ESP32 |
| `robot/commands/unlock` | cloud → robot | 1 | Go gateway | ESP32 |
| `robot/status/heartbeat` | robot → cloud | 1 | Pi, ESP32 | Go gateway |
| `robot/telemetry` | robot → cloud | 0 | Raspberry Pi | Go gateway |

### `robot/commands/navigate` payload

Published by `OrderService.Dispatch` on a successful order.

```json
{
  "order_id": "order_1714000000123",
  "destination": { "x": 12.0, "y": -3.5 },
  "issued_at": 1714000000
}
```

### `robot/commands/display_qr` payload

Published by `WakeDisplayService.WakeDisplay` when the customer taps "Scan" in Flutter.

```json
{
  "order_id": "order_1714000000123",
  "otp": "7429",
  "issued_at": 1714000000
}
```

ESP32 firmware validates: `otp` must be exactly 4 ASCII digit characters. Stores `order_id` in `_pendingOrderId` for unlock cross-validation.

### `robot/commands/unlock` payload

Published by `OTPService.ValidateAndUnlock` after successful OTP validation.

```json
{
  "order_id": "order_1714000000123",
  "code": "7429",
  "issued_at": 1714000000
}
```

ESP32 firmware rejects the command if `order_id` does not match `_pendingOrderId` (MFA sequencing invariant).

### `robot/status/heartbeat` payload

Published every 30 s by the ESP32. Also used as LWT (`{"source":"esp32","status":"offline"}`).

```json
{
  "source": "esp32",
  "status": "online",
  "uptime_s": 3600,
  "rssi_dbm": -62,
  "free_heap": 218432,
  "actuator_armed": false,
  "display_ready": true,
  "pending_order": "order_1714000000123"
}
```

`pending_order` is `""` when idle. `display_ready` is `false` if the SSD1306 failed I2C initialisation (robot can still operate — unlock via manual OTP still works).

---

## Flutter sealed result types

All API calls return sealed classes — `switch` is exhaustive at compile time.

| Method | Return type | Variants |
|---|---|---|
| `dispatchOrder()` | `DispatchResult?` | `null` on network error |
| `wakeDisplay()` | `WakeDisplayResult` | `WakeDisplayTriggered`, `WakeDisplayNotFound`, `WakeDisplayUnreachable`, `WakeDisplayNetworkError` |
| `validateOtp()` | `UnlockResult` | `UnlockSuccess`, `UnlockInvalidCode`, `UnlockRobotUnreachable`, `UnlockNetworkError` |
