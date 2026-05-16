# UnBot Delivery — State Flows & Invariants

## On-demand optical MFA — full sequence

This is the primary delivery sequence introduced in Phase 1.5. The QR Code is rendered lazily (when the customer initiates the scan), not eagerly (at dispatch time).

```mermaid
sequenceDiagram
    actor Customer
    participant App as Flutter app
    participant GW as Go gateway
    participant MQ as Mosquitto broker
    participant ESP as ESP32 (lock + OLED)
    participant PI as Raspberry Pi (ROS 2)

    Customer->>App: Selects restaurant + confirms order
    App->>GW: POST /api/orders/{id}/dispatch
    GW->>GW: IssueOTP() → store in memory
    GW->>MQ: PUBLISH robot/commands/navigate (QoS 1)
    MQ->>PI: DELIVER navigate payload
    PI-->>PI: nav2 starts routing
    GW-->>App: 200 {otp_code, gateway_mode}
    App->>App: addOrder() → navigate to TrackingScreen

    Note over Customer,App: Robot travels to delivery address

    Customer->>App: Taps "Scan robot & open"
    App->>App: setState(_isValidating = true)
    App->>GW: POST /api/orders/{id}/wake-display
    GW->>GW: LookupByOrderID() → retrieve OTP
    GW->>MQ: PUBLISH robot/commands/display_qr (QoS 1)
    MQ->>ESP: DELIVER display_qr payload
    ESP->>ESP: Validate OTP format (4 digits)
    ESP->>ESP: Store _pendingOrderId
    ESP->>ESP: showQrCode() → render on OLED (~50 ms)
    GW-->>App: 200 {triggered: true}
    App->>App: push QrScannerScreen (~200 ms after GW response)

    Note over Customer,ESP: OLED is ready before camera focuses

    Customer->>App: Scans QR Code on OLED
    App->>App: _onDetect() validates rawValue == expectedCode
    App->>GW: POST /api/validate-code {code, order_id}
    GW->>GW: ValidateAndUnlock() — acquire mutex
    GW->>GW: Mark code as Consumed
    GW->>GW: Release mutex
    GW->>MQ: PUBLISH robot/commands/unlock (QoS 1)
    MQ->>ESP: DELIVER unlock payload
    ESP->>ESP: Cross-validate order_id == _pendingOrderId
    ESP->>ESP: showUnlockSuccess() → display ✓
    ESP->>ESP: GPIO 2 HIGH → solenoid fires (5 000 ms hold)
    ESP->>ESP: Clear _pendingOrderId
    GW-->>App: 200 {unlocked: true}
    App->>App: removeOrder(orderId, reason: 'completed')
    App->>App: setState(_codeUsed = true)
```

---

## Degraded mode — MQTT unreachable at dispatch

```mermaid
sequenceDiagram
    participant App as Flutter app
    participant GW as Go gateway
    participant MQ as Mosquitto broker

    App->>GW: POST /api/orders/{id}/dispatch
    GW->>GW: IssueOTP() → success
    GW->>MQ: PUBLISH robot/commands/navigate
    MQ--xGW: publish timeout / connection lost
    GW-->>App: 200 {gateway_mode: "otp_only", mqtt_connected: false}
    App->>App: addOrder() — isOtpOnly = true
    App->>App: Show Wi-Fi-off badge on order card
    Note over App: Customer can still validate OTP manually<br/>Robot will receive navigate when connection restores
```

---

## Wake-display failure paths

```mermaid
sequenceDiagram
    participant App as Flutter app
    participant GW as Go gateway

    App->>GW: POST /api/orders/{id}/wake-display

    alt Order not found / OTP consumed
        GW-->>App: 404 {error}
        App->>App: Show error snackbar
        App->>App: setState(_isValidating = false)
        Note over App: Manual OTP entry remains available
    else MQTT unreachable
        GW-->>App: 502 {error}
        App->>App: Show _showWakeFailureDialog()
        App->>App: setState(_isValidating = false)
        Note over App: Dialog offers "Use manual code" or "Retry"
    else Network error / timeout
        GW--xApp: TimeoutException / socket error
        App->>App: WakeDisplayNetworkError returned
        App->>App: Show _showWakeFailureDialog()
        App->>App: setState(_isValidating = false)
    end
```

---

## Go OTP service — state invariants

```
OTPRecord.Consumed transitions: false → true (one-way, irreversible)

ValidateAndUnlock critical section:
  1. Acquire mu
  2. Look up code → if absent: release mu, return ErrInvalidCode
  3. If Consumed: release mu, return ErrConsumed
  4. Set Consumed = true
  5. Release mu          ← code is consumed before MQTT publish
  6. Publish unlock
  7. If publish fails: return ErrPublish (code already consumed — no replay)

Invariant: a code can open exactly one compartment, regardless of
concurrent requests, MQTT failures, or client retries.
```

---

## ESP32 connection state machine

```mermaid
stateDiagram-v2
    [*] --> CS_BOOT
    CS_BOOT --> CS_WIFI_CONNECTING : begin()
    CS_WIFI_CONNECTING --> CS_WIFI_CONNECTING : timeout → restart WiFi.begin()
    CS_WIFI_CONNECTING --> CS_WIFI_CONNECTED : WL_CONNECTED
    CS_WIFI_CONNECTED --> CS_MQTT_CONNECTING : immediate (next tick)
    CS_MQTT_CONNECTING --> CS_MQTT_CONNECTING : connect fail → exponential backoff (2s→60s)
    CS_MQTT_CONNECTING --> CS_MQTT_CONNECTED : client.connected()
    CS_MQTT_CONNECTED --> CS_WIFI_LOST : WiFi.status() ≠ WL_CONNECTED
    CS_MQTT_CONNECTED --> CS_MQTT_LOST : !client.connected()
    CS_WIFI_LOST --> CS_WIFI_CONNECTING : startWifi()
    CS_MQTT_LOST --> CS_MQTT_CONNECTING : attemptMqttConnect()
```

**Key invariant**: `client.loop()` is called **only** in `CS_MQTT_CONNECTED`. Calling it in any other state reads from a null/stale TCP socket and can trigger a hard fault on ESP-IDF.

---

## Flutter `ValueNotifier` mutation rules

All three global notifiers follow the same immutable-swap protocol:

```
// CORRECT — triggers listeners
activeOrdersNotifier.value = [...current, newOrder];

// WRONG — mutates list in place, listeners DO NOT fire
activeOrdersNotifier.value.add(newOrder);  // ← NEVER DO THIS
```

`removeOrder()` is atomic from the UI's perspective:
1. Find departing order in `activeOrdersNotifier.value`
2. Call `archivePastOrder()` → prepend to `pastOrdersNotifier.value`
3. Write filtered list to `activeOrdersNotifier.value`

Both notifiers fire in the same synchronous call stack. No frame exists where an order is absent from both lists simultaneously.

---

## Active order lifecycle

```
Placement          Tracking           Pickup              Archive
─────────          ────────           ──────              ───────
addOrder()    →    activeOrdersNotifier  →  removeOrder(    →  pastOrdersNotifier
                   isOtpOnly badge          reason: 'completed'   reason badge:
                   TrackingScreen           or 'cancelled')       'Entregue' / 'Cancelado'
```

`reason: 'completed'` is set by `code_screen.dart` (OTP validated).  
`reason: 'cancelled'` is set by the cancel dialog in `tracking_screen.dart`.  
Default parameter on `removeOrder()` is `'completed'` — callers at non-happy-path sites must be **explicit**.
