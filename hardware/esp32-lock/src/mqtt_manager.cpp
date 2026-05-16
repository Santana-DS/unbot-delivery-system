// =============================================================================
// src/mqtt_manager.cpp
//
// UnBot Delivery — ESP32 MQTT Connection Manager (Implementation)
// -----------------------------------------------------------------------------
// FIXES APPLIED (v2.1):
//   FIX 1 — No digit separators anywhere in this file.
//   FIX 2 — Every ConnectionState reference uses the CS_ prefix throughout:
//            CS_BOOT, CS_WIFI_CONNECTING, CS_WIFI_CONNECTED,
//            CS_MQTT_CONNECTING, CS_MQTT_CONNECTED, CS_WIFI_LOST, CS_MQTT_LOST.
//            This includes all switch() cases, _setState() calls, comparisons,
//            and the connectionStateName() helper at the bottom of the file.
//   FIX 3 — _startWifi() and _attemptMqttConnect() are now declared in the
//            header. Implementation is unchanged; the linker error is resolved
//            by the header fix alone.
//
// See mqtt_manager.h for the full design contract.
//
// STATE MACHINE DIAGRAM:
//
//   CS_BOOT
//    │  begin() called
//    ▼
//   CS_WIFI_CONNECTING ──timeout──► CS_WIFI_CONNECTING (restart WiFi.begin)
//    │  WL_CONNECTED
//    ▼
//   CS_WIFI_CONNECTED
//    │  (immediate, next tick)
//    ▼
//   CS_MQTT_CONNECTING ──fail──► backoff ──► CS_MQTT_CONNECTING
//    │  client.connected()
//    ▼
//   CS_MQTT_CONNECTED ◄──────────────────────────────────────────┐
//    │  WiFi drops          │  MQTT drops (WiFi still up)        │
//    ▼                      ▼                                    │
//   CS_WIFI_LOST        CS_MQTT_LOST                             │
//    │  reconnect           │  reconnect                         │
//    └──► CS_WIFI_CONNECTING └──► CS_MQTT_CONNECTING ────────────┘
//
// KEY INVARIANT: client.loop() is called ONLY in CS_MQTT_CONNECTED state.
// Calling it in any other state causes PubSubClient to attempt a TCP read
// on a null or stale socket, which can trigger a hard fault on ESP-IDF.
// =============================================================================

#include "mqtt_manager.h"
#include <Arduino.h>

// Static instance pointer for the callback trampoline.
// Exactly one MqttManager per firmware — singleton is safe here.
MqttManager* MqttManager::_instance = nullptr;

// =============================================================================
// Constructor
// =============================================================================
MqttManager::MqttManager(
    const char*         ssid,
    const char*         password,
    const char*         brokerIp,
    uint16_t            brokerPort,
    const char*         clientId,
    const char*         mqttUser,
    const char*         mqttPass,
    MqttMessageCallback callback
)
    : _ssid(ssid)
    , _password(password)
    , _brokerIp(brokerIp)
    , _brokerPort(brokerPort)
    , _clientId(clientId)
    , _mqttUser(mqttUser)
    , _mqttPass(mqttPass)
    , _userCallback(callback)
    , _state(ConnectionState::CS_BOOT)
    , _backoffMs(MQTT_BACKOFF_BASE_MS)
    , _lastAttemptMs(0)
    , _lastLoopMs(0)
    , _wifiStartMs(0)
{
    // Wire PubSubClient to our WiFiClient and broker coordinates.
    _client.setClient(_wifiClient);
    _client.setServer(_brokerIp, _brokerPort);

    // Register the static trampoline as PubSubClient's callback.
    // _staticCallback forwards to _userCallback via _instance.
    _instance = this;
    _client.setCallback(_staticCallback);

    // Increase PubSubClient's internal buffer beyond the 256-byte default.
    // Our unlock payload is ~120 bytes but leave headroom for future fields.
    // 512 bytes is well within ESP32's 520 KB SRAM.
    _client.setBufferSize(512);

    // Set keep-alive to 30 s. The Mosquitto broker's max_keepalive in
    // unbot.conf is 60 s, so 30 s gives a 2x safety margin before the
    // broker fires the Last Will and considers this client dead.
    _client.setKeepAlive(30);
}

// =============================================================================
// begin() — call once from setup()
// =============================================================================
void MqttManager::begin() {
    Serial.println(F("[MQTT] Manager starting — firmware v2.1"));
    Serial.printf("[MQTT] Broker target: %s:%d\n", _brokerIp, _brokerPort);
    Serial.printf("[MQTT] Client ID: %s\n", _clientId);

    // Disable the ESP32 Wi-Fi modem sleep mode.
    // Default modem sleep introduces up to 100 ms of receive latency because
    // the radio duty-cycles to save power. For a lock actuator, deterministic
    // low latency is more important than battery savings.
    WiFi.setSleep(false);

    // WIFI_STA = station mode (client). Must be set before WiFi.begin().
    WiFi.mode(WIFI_STA);

    _setState(ConnectionState::CS_WIFI_CONNECTING);
    _startWifi();
}

// =============================================================================
// tick() — call every loop() iteration
// =============================================================================
void MqttManager::tick() {
    switch (_state) {
        case ConnectionState::CS_BOOT:             _handleBoot();            break;
        case ConnectionState::CS_WIFI_CONNECTING:  _handleWifiConnecting();  break;
        case ConnectionState::CS_WIFI_CONNECTED:   _handleWifiConnected();   break;
        case ConnectionState::CS_MQTT_CONNECTING:  _handleMqttConnecting();  break;
        case ConnectionState::CS_MQTT_CONNECTED:   _handleMqttConnected();   break;
        case ConnectionState::CS_WIFI_LOST:        _handleWifiLost();        break;
        case ConnectionState::CS_MQTT_LOST:        _handleMqttLost();        break;
    }
}

// =============================================================================
// publish()
// =============================================================================
bool MqttManager::publish(const char* topic, const char* payload, bool retained) {
    if (_state != ConnectionState::CS_MQTT_CONNECTED) {
        Serial.printf("[MQTT] publish() skipped — not connected (state: %s)\n",
                      connectionStateName(_state));
        return false;
    }
    bool ok = _client.publish(topic, payload, retained);
    if (!ok) {
        Serial.printf("[MQTT] publish() failed on topic: %s\n", topic);
    }
    return ok;
}

// =============================================================================
// isConnected()
// =============================================================================
bool MqttManager::isConnected() const {
    return _state == ConnectionState::CS_MQTT_CONNECTED;
}

// =============================================================================
// subscribe()
// =============================================================================
bool MqttManager::subscribe(const char* topic, uint8_t qos) {
    if (_state != ConnectionState::CS_MQTT_CONNECTED) {
        Serial.println(F("[MQTT] subscribe() skipped — not connected"));
        return false;
    }
    bool ok = _client.subscribe(topic, qos);
    Serial.printf("[MQTT] subscribe %s (QoS %d): %s\n",
                  topic, qos, ok ? "OK" : "FAIL");
    return ok;
}

// =============================================================================
// State handlers — private
// =============================================================================

void MqttManager::_handleBoot() {
    // Should not linger in CS_BOOT after begin() is called.
    // begin() transitions directly to CS_WIFI_CONNECTING.
    // This handler exists as a safety net in case tick() is called before
    // begin() — it self-heals rather than hanging silently.
    _setState(ConnectionState::CS_WIFI_CONNECTING);
    _startWifi();
}

void MqttManager::_handleWifiConnecting() {
    wl_status_t status = WiFi.status();

    if (status == WL_CONNECTED) {
        Serial.printf("[WiFi] Connected. IP: %s  RSSI: %d dBm\n",
                      WiFi.localIP().toString().c_str(),
                      WiFi.RSSI());
        _setState(ConnectionState::CS_WIFI_CONNECTED);
        return;
    }

    // Timeout guard: if WiFi.begin() has been pending longer than
    // WIFI_CONNECT_TIMEOUT_MS, restart the attempt. This handles the case
    // where the ESP32 Wi-Fi driver gets stuck — common on WPA2-Enterprise
    // networks and some campus captive portals.
    if (millis() - _wifiStartMs > WIFI_CONNECT_TIMEOUT_MS) {
        Serial.println(F("[WiFi] Connection timeout — restarting attempt..."));
        WiFi.disconnect(true);  // true = also clear credentials from RAM
        delay(100);             // Brief settle; acceptable here (pre-MQTT, in setup phase)
        _startWifi();
    }
    // Otherwise keep waiting; loop() returns immediately.
}

void MqttManager::_handleWifiConnected() {
    // Wi-Fi just came up. Reset backoff and start MQTT connection attempt
    // on the very next tick. _handleMqttConnecting() manages its own backoff
    // from here.
    _resetBackoff();
    _setState(ConnectionState::CS_MQTT_CONNECTING);
    _attemptMqttConnect();
}

void MqttManager::_handleMqttConnecting() {
    if (_client.connected()) {
        // client.connect() already succeeded (it is synchronous in PubSubClient).
        // _onMqttConnect() was called inside _attemptMqttConnect() on success,
        // but we call it again here defensively — it is idempotent.
        _onMqttConnect();
        _resetBackoff();
        _setState(ConnectionState::CS_MQTT_CONNECTED);
        return;
    }

    // Has the backoff window elapsed? If not, return immediately.
    if (millis() - _lastAttemptMs < _backoffMs) {
        return;
    }

    Serial.printf("[MQTT] Retrying connect (backoff was: %lu ms)...\n", _backoffMs);
    _advanceBackoff();

    // Guard: Wi-Fi may have dropped between the last attempt and this tick.
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println(F("[MQTT] Wi-Fi lost during MQTT reconnect — reverting to CS_WIFI_LOST"));
        _setState(ConnectionState::CS_WIFI_LOST);
        return;
    }

    _attemptMqttConnect();
}

void MqttManager::_handleMqttConnected() {
    // Guard 1: Wi-Fi dropped — the more serious failure.
    // Check this first; a Wi-Fi loss also invalidates the TCP socket underlying
    // the MQTT connection.
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println(F("[WiFi] Connection lost in CS_MQTT_CONNECTED state"));
        _client.disconnect();  // Clean TCP teardown before the network disappears
        _setState(ConnectionState::CS_WIFI_LOST);
        return;
    }

    // Guard 2: MQTT broker connection dropped (TCP reset, broker restart,
    // keep-alive timeout, etc.).
    if (!_client.connected()) {
        int rc = _client.state();
        // PubSubClient state codes for reference:
        //  -4 MQTT_CONNECTION_TIMEOUT  — broker didn't respond in time
        //  -3 MQTT_CONNECTION_LOST     — TCP connection dropped
        //  -2 MQTT_CONNECT_FAILED      — TCP refused (wrong IP/port)
        //  -1 MQTT_DISCONNECTED        — clean disconnect or not started
        //   3 MQTT_CONNECT_BAD_CREDENTIALS — check secrets.h passwords
        //   5 MQTT_CONNECT_UNAUTHORIZED
        Serial.printf("[MQTT] Broker connection lost (PubSubClient state: %d)\n", rc);
        _setState(ConnectionState::CS_MQTT_LOST);
        return;
    }

    // Steady state: drive the PubSubClient event loop.
    // client.loop() must be called frequently to:
    //   a) Deliver inbound PUBLISH messages to our callback.
    //   b) Send PINGREQ keep-alive packets before the broker times us out.
    //   c) Process QoS 1 PUBACK acknowledgements.
    // Rate-limited to MQTT_LOOP_INTERVAL_MS to avoid burning 100% CPU
    // while still keeping the keep-alive well within the 30 s window.
    if (millis() - _lastLoopMs >= MQTT_LOOP_INTERVAL_MS) {
        _client.loop();
        _lastLoopMs = millis();
    }
}

void MqttManager::_handleWifiLost() {
    Serial.println(F("[WiFi] Attempting reconnection..."));
    _startWifi();
    _setState(ConnectionState::CS_WIFI_CONNECTING);
}

void MqttManager::_handleMqttLost() {
    // Wi-Fi is still up — skip full reconnect and jump straight to
    // CS_MQTT_CONNECTING with its built-in backoff.
    Serial.println(F("[MQTT] Wi-Fi still up — attempting MQTT reconnect..."));
    _resetBackoff();
    _setState(ConnectionState::CS_MQTT_CONNECTING);
    _attemptMqttConnect();
}

// =============================================================================
// Connection action methods — private
// =============================================================================

void MqttManager::_startWifi() {
    Serial.printf("[WiFi] Connecting to SSID: %s\n", _ssid);
    WiFi.begin(_ssid, _password);
    _wifiStartMs = millis();
}

void MqttManager::_attemptMqttConnect() {
    Serial.printf("[MQTT] Connecting to %s:%d as '%s'...\n",
                  _brokerIp, _brokerPort, _clientId);

    // Last Will and Testament (LWT):
    // If this client disconnects uncleanly (power loss, TCP reset, watchdog),
    // the broker publishes this payload automatically on our behalf.
    // The Go gateway's handleHeartbeat stub receives it and can mark the
    // lock actuator offline in the dashboard.
    const char* lwtTopic   = "robot/status/heartbeat";
    const char* lwtPayload = "{\"source\":\"esp32\",\"status\":\"offline\"}";

    bool ok = _client.connect(
        _clientId,
        _mqttUser,
        _mqttPass,
        lwtTopic,    // LWT topic
        1,           // LWT QoS 1
        false,       // LWT retained = false (stale offline status should not
                     // persist across a broker restart)
        lwtPayload
    );

    _lastAttemptMs = millis();

    if (ok) {
        Serial.println(F("[MQTT] Connected to broker."));
        _onMqttConnect();
        // Caller (_handleWifiConnected or _handleMqttConnecting) will
        // call _resetBackoff() and transition to CS_MQTT_CONNECTED.
    } else {
        int rc = _client.state();
        Serial.printf("[MQTT] Connect failed (state: %d). Next retry in %lu ms.\n",
                      rc, _backoffMs);
    }
}

// =============================================================================
// Shared utility methods — private
// =============================================================================

void MqttManager::_onMqttConnect() {
    Serial.println(F("[MQTT] Subscribing to command topics..."));

    // ── Topic 1: display_qr ───────────────────────────────────────────────
    // Go gateway publishes here after POST /api/orders/{id}/dispatch succeeds.
    // The ESP32 renders the OTP as a QR Code on the OLED.
    // QoS 1: at-least-once delivery. The display is idempotent — showing the
    // same QR twice is safe and preferable to missing it.
    bool displaySub = _client.subscribe("robot/commands/display_qr", 1);
    Serial.printf("[MQTT]   robot/commands/display_qr (QoS 1): %s\n",
                  displaySub ? "OK" : "FAIL");

    // ── Topic 2: unlock ───────────────────────────────────────────────────
    // Go gateway publishes here after OTP validated via POST /api/validate-code.
    // The ESP32 clears the QR, shows the success screen, and fires the GPIO.
    // QoS 1: at-least-once. The actuator handler is idempotent (re-arming
    // resets armTimeMs, extending the hold — acceptable in a retry scenario).
    bool unlockSub = _client.subscribe("robot/commands/unlock", 1);
    Serial.printf("[MQTT]   robot/commands/unlock     (QoS 1): %s\n",
                  unlockSub ? "OK" : "FAIL");

    // ── Online heartbeat ──────────────────────────────────────────────────
    // Immediate publish so MQTT Explorer and the Go gateway know the actuator
    // is live without waiting for the first scheduled heartbeat (30 s).
    _client.publish(
        "robot/status/heartbeat",
        "{\"source\":\"esp32\",\"status\":\"online\"}",
        false
    );
}


void MqttManager::_resetBackoff() {
    _backoffMs = MQTT_BACKOFF_BASE_MS;
}

void MqttManager::_advanceBackoff() {
    // Exponential doubling capped at MQTT_BACKOFF_MAX_MS.
    // Sequence (ms): 2000 → 4000 → 8000 → 16000 → 32000 → 60000 → 60000 → ...
    if (_backoffMs < MQTT_BACKOFF_MAX_MS) {
        _backoffMs = (_backoffMs * 2 < MQTT_BACKOFF_MAX_MS)
                         ? _backoffMs * 2
                         : MQTT_BACKOFF_MAX_MS;
    }
}

void MqttManager::_setState(ConnectionState next) {
    if (next == _state) return;  // Suppress duplicate log lines on repeated ticks.
    Serial.printf("[STATE] %s → %s\n",
                  connectionStateName(_state),
                  connectionStateName(next));
    _state = next;
}

// =============================================================================
// Static callback trampoline
// PubSubClient requires a plain C function pointer. We bridge it to the
// instance method via the static _instance pointer set in the constructor.
// =============================================================================
void MqttManager::_staticCallback(char* topic, uint8_t* payload, unsigned int len) {
    if (_instance != nullptr && _instance->_userCallback) {
        _instance->_userCallback(topic, payload, len);
    }
}

// =============================================================================
// connectionStateName() — diagnostic helper (free function, declared in .h)
//
// FIX 2: All switch cases updated to use CS_ prefix to match the corrected
// enum definition. Without this change the switch would have failed to compile
// with the same macro collision that broke the enum.
// =============================================================================
const char* connectionStateName(ConnectionState s) {
    switch (s) {
        case ConnectionState::CS_BOOT:             return "CS_BOOT";
        case ConnectionState::CS_WIFI_CONNECTING:  return "CS_WIFI_CONNECTING";
        case ConnectionState::CS_WIFI_CONNECTED:   return "CS_WIFI_CONNECTED";
        case ConnectionState::CS_MQTT_CONNECTING:  return "CS_MQTT_CONNECTING";
        case ConnectionState::CS_MQTT_CONNECTED:   return "CS_MQTT_CONNECTED";
        case ConnectionState::CS_WIFI_LOST:        return "CS_WIFI_LOST";
        case ConnectionState::CS_MQTT_LOST:        return "CS_MQTT_LOST";
        default:                                   return "CS_UNKNOWN";
    }
}