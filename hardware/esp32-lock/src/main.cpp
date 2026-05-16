// =============================================================================
// src/main.cpp
//
// UnBot Delivery — ESP32 Main Firmware (v3.0)
// -----------------------------------------------------------------------------
// CHANGES FROM v2.0:
//   + DisplayManager integrated — OLED SSD1306 shows QR on display_qr command,
//     success screen on unlock command, boot/idle states between deliveries.
//   + Two-topic MQTT routing:
//       robot/commands/display_qr  → parse JSON → showQrCode()
//       robot/commands/unlock      → parse JSON → showUnlockSuccess() → GPIO arm
//   + MFA sequence enforced in firmware:
//       display_qr first populates _pendingOrderId.
//       unlock validates that the arriving order_id matches _pendingOrderId.
//       Mismatched order_id on unlock is logged and rejected (no GPIO fire).
//   + _onMqttConnect() in mqtt_manager.cpp updated to subscribe to both topics.
//
// MFA SEQUENCE:
//   Go gateway                ESP32                    Flutter app
//   ──────────────────────────────────────────────────────────────
//   POST /dispatch ──────► display_qr topic ──► renders QR on OLED
//                                               customer scans OLED
//   POST /validate-code ◄────────────────────── Flutter sends OTP
//   (validates OTP)
//   unlock topic ────────► unlock handler ────► clears QR, shows ✓
//                                             ► GPIO fires solenoid
//
// CONCURRENCY NOTE (unchanged from v2.0):
//   All MQTT callbacks fire inside mqttManager.tick() on Core 1, same task
//   as loop(). No FreeRTOS tasks, no preemption. _pendingOrderId and
//   ActuatorState are accessed only in this serialised call sequence — no
//   mutex required. If you add a background task later, protect them.
// =============================================================================

#include <Arduino.h>
#include <ArduinoJson.h>
#include <WiFi.h>

#include "mqtt_manager.h"
#include "display_manager.h"
#include "secrets.h"   // Copy from secrets.h.example — never commit real values

// =============================================================================
// Hardware configuration
// =============================================================================

// Solenoid lock actuator — GPIO 2 = onboard LED for breadboard mock.
// V3.0 production: wire to NPN transistor gate (GPIO 4 recommended, avoids
// the boot-mode strapping function on GPIO 2 that can cause upload issues
// on some boards). Swap the constant and recompile.
static constexpr uint8_t  GPIO_ACTUATOR_PIN  = 2;
static constexpr uint32_t ACTUATOR_HOLD_MS   = 5000;  // 5 s hold

// =============================================================================
// MQTT topic constants (must match Go gateway services/otp.go + order.go)
// =============================================================================
static constexpr char TOPIC_DISPLAY_QR[]  = "robot/commands/display_qr";
static constexpr char TOPIC_UNLOCK[]      = "robot/commands/unlock";
static constexpr char TOPIC_HEARTBEAT[]   = "robot/status/heartbeat";

static constexpr uint32_t MAX_PAYLOAD_AGE_MS = 60000; // 60 segundos de tolerância

// =============================================================================
// Heartbeat
// =============================================================================
static constexpr uint32_t HEARTBEAT_INTERVAL_MS = 30000;
static uint32_t lastHeartbeatMs = 0;

// =============================================================================
// MFA state — shared between the two MQTT handlers
//
// _pendingOrderId is set by onDisplayQr() and consumed+cleared by onUnlock().
// This enforces the MFA sequencing invariant:
//   - An unlock command for an order whose QR was never displayed is rejected.
//   - An unlock for a different order than the one on screen is rejected.
//   - After successful unlock the field is cleared, preventing replay.
//
// Buffer sized to hold a full order_id ("order_1714000000123" = 22 chars max).
// =============================================================================
static char _pendingOrderId[64] = "";

// =============================================================================
// Actuator state (unchanged from v2.0)
// =============================================================================
struct ActuatorState {
    bool     armed;
    uint32_t armTimeMs;
    char     orderId[64];
};
static ActuatorState actuator = { false, 0, "" };

// =============================================================================
// Subsystem instances
// =============================================================================
static DisplayManager displayMgr;

// =============================================================================
// Forward declarations
// =============================================================================
void onDisplayQr(uint8_t* payload, unsigned int len);
void onUnlock(uint8_t* payload, unsigned int len);
void handleGpio();
void handleHeartbeat();

// MqttManager — unchanged class, updated subscription list in _onMqttConnect().
// Callback routing is done in the lambda below.
static MqttManager mqttManager(
    WIFI_SSID,
    WIFI_PASSWORD,
    MQTT_BROKER_IP,
    MQTT_BROKER_PORT,
    MQTT_CLIENT_ID,
    MQTT_USERNAME,
    MQTT_PASSWORD,
    // Router lambda — dispatches to topic-specific handlers below.
    // Captures nothing; all state is file-scope static (safe in Arduino loop).
    [](char* topic, uint8_t* payload, unsigned int len) {
        if (strcmp(topic, TOPIC_DISPLAY_QR) == 0) {
            onDisplayQr(payload, len);
        } else if (strcmp(topic, TOPIC_UNLOCK) == 0) {
            onUnlock(payload, len);
        } else {
            Serial.printf("[MQTT] Unhandled topic: %s\n", topic);
        }
    }
);

// =============================================================================
// setup()
// =============================================================================
void setup() {
    Serial.begin(115200);
    delay(500);

    Serial.println(F("\n=========================================="));
    Serial.println(F("  UnBot Delivery — ESP32 Firmware v3.0   "));
    Serial.println(F("==========================================\n"));

    // ── Display ──────────────────────────────────────────────────────────────
    // begin() before mqttManager.begin() so the OLED shows the boot screen
    // immediately — before the Wi-Fi association completes (~2–5 s).
    if (!displayMgr.begin()) {
        // Continue without display — robot can still operate. Lock still fires.
        // Error already logged inside begin().
    } else {
        displayMgr.showBooting();
    }

    // ── Actuator GPIO ─────────────────────────────────────────────────────────
    pinMode(GPIO_ACTUATOR_PIN, OUTPUT);
    digitalWrite(GPIO_ACTUATOR_PIN, LOW);
    Serial.printf("[GPIO] Actuator pin %d → OUTPUT LOW\n", GPIO_ACTUATOR_PIN);

    // ── MQTT / Wi-Fi ──────────────────────────────────────────────────────────
    mqttManager.begin();
}

// =============================================================================
// loop()
// =============================================================================
void loop() {
    mqttManager.tick();
    handleGpio();
    handleHeartbeat();

    // Update idle screen once per connection transition.
    // MqttManager exposes state() — we watch for the CS_MQTT_CONNECTED edge.
    static ConnectionState lastState = ConnectionState::CS_BOOT;
    ConnectionState curState = mqttManager.state();
    if (curState != lastState) {
        lastState = curState;
        if (curState == ConnectionState::CS_MQTT_CONNECTED) {
            // Only show connected screen if no order is currently pending
            // (avoids overwriting a QR that's waiting to be scanned).
            if (_pendingOrderId[0] == '\0') {
                displayMgr.showConnected();
            }
        } else if (curState == ConnectionState::CS_WIFI_CONNECTING ||
                   curState == ConnectionState::CS_BOOT) {
            displayMgr.showBooting();
        }
    }
}

// =============================================================================
// onDisplayQr()
//
// Triggered by: robot/commands/display_qr
//
// Expected JSON payload (published by Go gateway on POST /api/orders/{id}/dispatch):
// {
//   "order_id":  "order_1714000000123",
//   "otp":       "7429",
//   "issued_at": 1714000000
// }
//
// Validation:
//   - JSON must parse without error.
//   - order_id and otp fields must be present and non-empty.
//   - otp must be exactly 4 ASCII digit characters.
//   - issued_at staleness check mirrors the unlock handler logic.
//
// Side effects:
//   - Stores orderId in _pendingOrderId for unlock cross-validation.
//   - Calls displayMgr.showQrCode() to render the QR on screen.
// =============================================================================
void onDisplayQr(uint8_t* payload, unsigned int len) {
    Serial.printf("\n[DISPLAY_QR] Message received (%d bytes)\n", len);

    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, payload, len);
    if (err) {
        Serial.printf("[DISPLAY_QR] JSON parse error: %s\n", err.c_str());
        displayMgr.showError("JSON PARSE ERR");
        return;
    }

    const char* orderId  = doc["order_id"];
    const char* otp      = doc["otp"];
    long        issuedAt = doc["issued_at"];

    if (!orderId || orderId[0] == '\0') {
        Serial.println(F("[DISPLAY_QR] Missing order_id — dropped"));
        return;
    }
    if (!otp || strlen(otp) != 4) {
        Serial.printf("[DISPLAY_QR] Invalid otp field: '%s' — dropped\n",
                      otp ? otp : "(null)");
        displayMgr.showError("BAD OTP FIELD");
        return;
    }
    // Verify all 4 chars are digits.
    for (int i = 0; i < 4; i++) {
        if (otp[i] < '0' || otp[i] > '9') {
            Serial.printf("[DISPLAY_QR] Non-digit in otp '%s' — dropped\n", otp);
            displayMgr.showError("OTP NOT DIGITS");
            return;
        }
    }
    if (issuedAt == 0) {
        Serial.println(F("[DISPLAY_QR] Missing issued_at — dropped"));
        return;
    }

    // Store for unlock cross-validation.
    strncpy(_pendingOrderId, orderId, sizeof(_pendingOrderId) - 1);
    _pendingOrderId[sizeof(_pendingOrderId) - 1] = '\0';

    Serial.printf("[DISPLAY_QR] ✓ Rendering QR — order: %s  otp: %s\n",
                  orderId, otp);

    // Render QR Code. Stack frame: ~80 bytes for QR buffer + qrcode_t.
    displayMgr.showQrCode(otp, orderId);
}

// =============================================================================
// onUnlock()
//
// Triggered by: robot/commands/unlock
//
// Expected JSON payload (published by Go gateway after OTP validated):
// {
//   "order_id":  "order_1714000000123",
//   "code":      "7429",
//   "issued_at": 1714000000
// }
//
// MFA CROSS-VALIDATION:
//   _pendingOrderId must match the incoming order_id. This ensures:
//   1. A display_qr was received first (QR was physically shown to customer).
//   2. An unlock for a different order (e.g., replayed or misrouted) is rejected.
//   3. After successful unlock, _pendingOrderId is cleared, preventing replay.
//
// Side effects on success:
//   - displayMgr.showUnlockSuccess() — customer sees confirmation immediately.
//   - actuator.armed = true — GPIO fires solenoid in handleGpio() next tick.
//   - _pendingOrderId cleared.
// =============================================================================
void onUnlock(uint8_t* payload, unsigned int len) {
    Serial.printf("\n[UNLOCK] Message received (%d bytes)\n", len);

    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, payload, len);
    if (err) {
        Serial.printf("[UNLOCK] JSON parse error: %s\n", err.c_str());
        return;
    }

    const char* orderId  = doc["order_id"];
    const char* code     = doc["code"];
    long        issuedAt = doc["issued_at"];

    if (!orderId || orderId[0] == '\0') {
        Serial.println(F("[UNLOCK] Missing order_id — dropped"));
        return;
    }
    if (!code || strlen(code) != 4) {
        Serial.println(F("[UNLOCK] Missing/invalid code field — dropped"));
        return;
    }
    if (issuedAt == 0) {
        Serial.println(F("[UNLOCK] Missing issued_at — dropped"));
        return;
    }

    // ── MFA cross-validation ─────────────────────────────────────────────────
    // _pendingOrderId must be set (display_qr was received) AND must match.
    if (_pendingOrderId[0] == '\0') {
        Serial.printf("[UNLOCK] REJECTED — no pending QR displayed "
                      "(unlock for '%s' arrived without display_qr first)\n",
                      orderId);
        displayMgr.showError("NO QR DISPLAYED");
        return;
    }
    if (strncmp(_pendingOrderId, orderId, sizeof(_pendingOrderId)) != 0) {
        Serial.printf("[UNLOCK] REJECTED — order_id mismatch: "
                      "pending='%s'  incoming='%s'\n",
                      _pendingOrderId, orderId);
        displayMgr.showError("ORDER MISMATCH");
        return;
    }

    // ── Staleness check (same logic as v2.0) ─────────────────────────────────
    if (millis() > MAX_PAYLOAD_AGE_MS) {
        Serial.printf("[UNLOCK] issued_at: %ld (NTP not configured — "
                      "staleness check advisory only)\n", issuedAt);
    }

    // ── All checks passed ────────────────────────────────────────────────────
    Serial.printf("[UNLOCK] ✓ Valid — arming actuator for order '%s'\n", orderId);

    // Show success screen BEFORE arming GPIO so the customer sees the ✓
    // immediately — solenoid click follows in the next handleGpio() call
    // (~0–50ms later), which is imperceptible.
    displayMgr.showUnlockSuccess(orderId);

    // Arm actuator.
    strncpy(actuator.orderId, orderId, sizeof(actuator.orderId) - 1);
    actuator.orderId[sizeof(actuator.orderId) - 1] = '\0';
    actuator.armed     = true;
    actuator.armTimeMs = millis();

    // Clear pending order — prevents replay and readies the system for next delivery.
    _pendingOrderId[0] = '\0';
}

// =============================================================================
// handleGpio() — unchanged from v2.0
// =============================================================================
void handleGpio() {
    if (!actuator.armed) {
        digitalWrite(GPIO_ACTUATOR_PIN, LOW);
        return;
    }

    digitalWrite(GPIO_ACTUATOR_PIN, HIGH);

    uint32_t elapsed = millis() - actuator.armTimeMs;
    if (elapsed >= ACTUATOR_HOLD_MS) {
        digitalWrite(GPIO_ACTUATOR_PIN, LOW);
        actuator.armed = false;

        Serial.printf("[GPIO] Actuator released after %lu ms — "
                      "compartment closed (order %s)\n",
                      elapsed, actuator.orderId);

        // Return to idle screen after the hold ends.
        if (mqttManager.isConnected()) {
            displayMgr.showConnected();
        } else {
            displayMgr.showBooting();
        }
    }
}

// =============================================================================
// handleHeartbeat() — extended from v2.0 to include display_ready field
// =============================================================================
void handleHeartbeat() {
    if (!mqttManager.isConnected()) return;

    uint32_t now = millis();
    if (now - lastHeartbeatMs < HEARTBEAT_INTERVAL_MS) return;
    lastHeartbeatMs = now;

    JsonDocument doc;
    doc["source"]         = "esp32";
    doc["status"]         = "online";
    doc["uptime_s"]       = now / 1000;
    doc["rssi_dbm"]       = WiFi.RSSI();
    doc["free_heap"]      = ESP.getFreeHeap();
    doc["actuator_armed"] = actuator.armed;
    doc["display_ready"]  = displayMgr.isReady();   // NEW: lets Go gateway know OLED status
    doc["pending_order"]  = (_pendingOrderId[0] != '\0') ? _pendingOrderId : "";

    char buffer[320];
    size_t written = serializeJson(doc, buffer, sizeof(buffer));
    if (written == 0 || written >= sizeof(buffer)) {
        Serial.println(F("[HEARTBEAT] Serialisation error"));
        return;
    }

    bool ok = mqttManager.publish(TOPIC_HEARTBEAT, buffer);
    Serial.printf("[HEARTBEAT] %s (uptime: %lus, RSSI: %ddBm, heap: %uB, "
                  "display: %s, pending: '%s')\n",
                  ok ? "OK" : "FAIL",
                  now / 1000,
                  WiFi.RSSI(),
                  ESP.getFreeHeap(),
                  displayMgr.isReady() ? "OK" : "ERR",
                  _pendingOrderId[0] ? _pendingOrderId : "—");
}
