// =============================================================================
// src/mqtt_manager.cpp
//
// UnBot Delivery — ESP32 MQTT Connection Manager (Implementation)
// -----------------------------------------------------------------------------
// See mqtt_manager.h for the full design contract and public API.
//
// STATE MACHINE DIAGRAM:
//
//   BOOT
//    │  begin() called
//    ▼
//   WIFI_CONNECTING ──timeout──► WIFI_CONNECTING (restart WiFi.begin)
//    │  WL_CONNECTED
//    ▼
//   WIFI_CONNECTED
//    │  (immediate, next tick)
//    ▼
//   MQTT_CONNECTING ──fail──► backoff ──► MQTT_CONNECTING
//    │  client.connected()
//    ▼
//   MQTT_CONNECTED ◄────────────────────────────────────────────┐
//    │  WiFi drops          │  MQTT drops (WiFi still up)       │
//    ▼                      ▼                                   │
//   WIFI_LOST           MQTT_LOST                               │
//    │  reconnect          │  reconnect                         │
//    └──► WIFI_CONNECTING  └──► MQTT_CONNECTING ────────────────┘
//
// KEY INVARIANT: client.loop() is called ONLY in MQTT_CONNECTED state.
// Calling it in any other state causes PubSubClient to attempt a TCP read
// on a null socket, which triggers a hard fault on some ESP-IDF versions.
// =============================================================================

#include "mqtt_manager.h"
#include <Arduino.h>

// Static instance pointer for the callback trampoline.
// There is exactly one MqttManager per firmware — singleton pattern is safe.
MqttManager* MqttManager::_instance = nullptr;

// =============================================================================
// Constructor
// =============================================================================
MqttManager::MqttManager(
    const char* ssid,
    const char* password,
    const char* brokerIp,
    uint16_t    brokerPort,
    const char* clientId,
    const char* mqttUser,
    const char* mqttPass,
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
    , _state(ConnectionState::BOOT)
    , _backoffMs(MQTT_BACKOFF_BASE_MS)
    , _lastAttemptMs(0)
    , _lastLoopMs(0)
    , _wifiStartMs(0)
{
    // Wire PubSubClient to our WiFiClient and broker coordinates.
    _client.setClient(_wifiClient);
    _client.setServer(_brokerIp, _brokerPort);

    // PubSubClient requires a plain C function pointer for the callback.
    // We store `this` in the static slot and jump through _staticCallback.
    _instance = this;
    _client.setCallback(_staticCallback);

    // Increase PubSubClient's internal buffer for our JSON payloads.
    // Default is 256 bytes — our unlock payload is ~120 bytes but leave
    // headroom for future fields. 512 is safe on ESP32's 520KB SRAM.
    _client.setBufferSize(512);

    // Set keep-alive to 30 s. The broker's max_keepalive in mosquitto.conf
    // is 60 s, so 30 s gives a 2× safety margin before the broker considers
    // this client dead and fires the Last Will.
    _client.setKeepAlive(30);
}

// =============================================================================
// begin() — call once from setup()
// =============================================================================
void MqttManager::begin() {
    Serial.println(F("[MQTT] Manager starting — firmware v2.0"));
    Serial.printf("[MQTT] Broker target: %s:%d\n", _brokerIp, _brokerPort);
    Serial.printf("[MQTT] Client ID: %s\n", _clientId);

    // Disable the ESP32 Wi-Fi sleep mode. The default modem sleep mode
    // introduces up to 100 ms of latency on received MQTT packets because
    // the radio duty-cycles. For a lock actuator, deterministic low latency
    // matters more than power saving.
    WiFi.setSleep(false);

    // Persist the Wi-Fi configuration across reboots.
    // WIFI_STA = station mode (client), not access point.
    WiFi.mode(WIFI_STA);

    _setState(ConnectionState::WIFI_CONNECTING);
    _startWifi();
}

// =============================================================================
// tick() — call every loop() iteration
// =============================================================================
void MqttManager::tick() {
    switch (_state) {
        case ConnectionState::BOOT:            _handleBoot();           break;
        case ConnectionState::WIFI_CONNECTING: _handleWifiConnecting(); break;
        case ConnectionState::WIFI_CONNECTED:  _handleWifiConnected();  break;
        case ConnectionState::MQTT_CONNECTING: _handleMqttConnecting(); break;
        case ConnectionState::MQTT_CONNECTED:  _handleMqttConnected();  break;
        case ConnectionState::WIFI_LOST:       _handleWifiLost();       break;
        case ConnectionState::MQTT_LOST:       _handleMqttLost();       break;
    }
}

// =============================================================================
// publish() — send a message to the broker
// =============================================================================
bool MqttManager::publish(const char* topic, const char* payload, bool retained) {
    if (_state != ConnectionState::MQTT_CONNECTED) {
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
    return _state == ConnectionState::MQTT_CONNECTED;
}

// =============================================================================
// subscribe()
// =============================================================================
bool MqttManager::subscribe(const char* topic, uint8_t qos) {
    if (_state != ConnectionState::MQTT_CONNECTED) {
        Serial.printf("[MQTT] subscribe() skipped — not connected\n");
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
    // Should not linger in BOOT after begin() is called.
    // begin() transitions directly to WIFI_CONNECTING.
    // This handler exists as a safety net for misconfigured setups.
    _setState(ConnectionState::WIFI_CONNECTING);
    _startWifi();
}

void MqttManager::_handleWifiConnecting() {
    wl_status_t status = WiFi.status();

    if (status == WL_CONNECTED) {
        Serial.printf("[WiFi] Connected. IP: %s  RSSI: %d dBm\n",
                      WiFi.localIP().toString().c_str(),
                      WiFi.RSSI());
        _setState(ConnectionState::WIFI_CONNECTED);
        return;
    }

    // Timeout guard: if we have been waiting longer than WIFI_CONNECT_TIMEOUT_MS,
    // restart the connection attempt. This handles the case where WiFi.begin()
    // got stuck — common on ESP32 with certain WPA2-Enterprise networks.
    if (millis() - _wifiStartMs > WIFI_CONNECT_TIMEOUT_MS) {
        Serial.println(F("[WiFi] Connection timeout — restarting attempt..."));
        WiFi.disconnect(true);   // true = clear saved credentials from RAM
        delay(100);              // Brief settle; acceptable here (pre-MQTT)
        _startWifi();
    }
    // Otherwise, keep waiting. The loop() returns immediately.
}

void MqttManager::_handleWifiConnected() {
    // Wi-Fi just came up. Attempt MQTT connection on the very next tick.
    // No delay here — _handleMqttConnecting will manage its own backoff.
    _resetBackoff();
    _setState(ConnectionState::MQTT_CONNECTING);
    _attemptMqttConnect();
}

void MqttManager::_handleMqttConnecting() {
    if (_client.connected()) {
        // Connect attempt succeeded (PubSubClient is synchronous on connect).
        // _onMqttConnect() was already called by PubSubClient internally
        // but we call it explicitly here to be safe — it is idempotent.
        _onMqttConnect();
        _resetBackoff();
        _setState(ConnectionState::MQTT_CONNECTED);
        return;
    }

    // Check if backoff window has elapsed before retrying.
    if (millis() - _lastAttemptMs >= _backoffMs) {
        Serial.printf("[MQTT] Retrying connect (backoff: %lu ms)...\n", _backoffMs);
        _advanceBackoff();

        // Guard: Wi-Fi may have dropped between states.
        if (WiFi.status() != WL_CONNECTED) {
            Serial.println(F("[MQTT] Wi-Fi lost during MQTT connect — returning to WIFI_CONNECTING"));
            _setState(ConnectionState::WIFI_LOST);
            return;
        }

        _attemptMqttConnect();
    }
}

void MqttManager::_handleMqttConnected() {
    // Guard 1: Wi-Fi dropped — this is the more serious failure.
    // Detect it first; a Wi-Fi loss also invalidates the TCP socket.
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println(F("[WiFi] Connection lost in MQTT_CONNECTED state"));
        _client.disconnect();    // Clean TCP teardown before network is gone
        _setState(ConnectionState::WIFI_LOST);
        return;
    }

    // Guard 2: MQTT broker connection dropped (TCP reset, broker restart, etc.)
    if (!_client.connected()) {
        int rc = _client.state();
        Serial.printf("[MQTT] Broker connection lost (PubSubClient state: %d)\n", rc);
        _setState(ConnectionState::MQTT_LOST);
        return;
    }

    // Steady-state: drive the PubSubClient event loop.
    // client.loop() must be called frequently to:
    //   a) Process inbound PUBLISH messages (triggers our callback)
    //   b) Send PINGREQ keep-alive packets to the broker
    //   c) Acknowledge QoS 1 PUBACK responses
    // We rate-limit to MQTT_LOOP_INTERVAL_MS to avoid burning CPU while
    // still keeping the keep-alive well within the 30 s window.
    if (millis() - _lastLoopMs >= MQTT_LOOP_INTERVAL_MS) {
        _client.loop();
        _lastLoopMs = millis();
    }
}

void MqttManager::_handleWifiLost() {
    Serial.println(F("[WiFi] Attempting reconnection..."));
    _startWifi();
    _setState(ConnectionState::WIFI_CONNECTING);
}

void MqttManager::_handleMqttLost() {
    // Wi-Fi is still up — skip the full reconnect and go straight to
    // MQTT_CONNECTING with its built-in backoff.
    _resetBackoff();
    _setState(ConnectionState::MQTT_CONNECTING);
    _attemptMqttConnect();
}

// =============================================================================
// Private helpers
// =============================================================================

void MqttManager::_startWifi() {
    Serial.printf("[WiFi] Connecting to SSID: %s\n", _ssid);
    WiFi.begin(_ssid, _password);
    _wifiStartMs = millis();
}

void MqttManager::_attemptMqttConnect() {
    Serial.printf("[MQTT] Connecting to %s:%d as '%s'...\n",
                  _brokerIp, _brokerPort, _clientId);

    // Build Last Will and Testament payload.
    // Published automatically by the broker if this client disconnects
    // uncleanly (TCP reset, power loss). The Go gateway's handleHeartbeat
    // can detect this and mark the lock actuator offline.
    const char* lwtTopic   = "robot/status/heartbeat";
    const char* lwtPayload = "{\"source\":\"esp32\",\"status\":\"offline\"}";

    bool ok = _client.connect(
        _clientId,
        _mqttUser,
        _mqttPass,
        lwtTopic,    // Last Will topic
        1,           // Last Will QoS
        false,       // Last Will retained = false (stale LWT should not persist)
        lwtPayload   // Last Will message
    );

    _lastAttemptMs = millis();

    if (ok) {
        Serial.println(F("[MQTT] Connected to broker."));
        _onMqttConnect();
    } else {
        int rc = _client.state();
        // PubSubClient state codes:
        //  -4 = MQTT_CONNECTION_TIMEOUT
        //  -3 = MQTT_CONNECTION_LOST
        //  -2 = MQTT_CONNECT_FAILED  (TCP refused — wrong IP/port)
        //  -1 = MQTT_DISCONNECTED
        //   3 = MQTT_CONNECT_BAD_CREDENTIALS  ← check secrets.h
        //   5 = MQTT_CONNECT_UNAUTHORIZED
        Serial.printf("[MQTT] Connect failed (PubSubClient state: %d). "
                      "Next retry in %lu ms.\n", rc, _backoffMs);
    }
}

void MqttManager::_onMqttConnect() {
    // CRITICAL: Re-subscribe to ALL topics here, not once at startup.
    // PubSubClient does not store subscriptions — they are lost on every
    // disconnect. If you add topics, add them here.
    Serial.println(F("[MQTT] Subscribing to command topics..."));

    bool unlockSub = _client.subscribe("robot/commands/unlock", 1);
    Serial.printf("[MQTT]   robot/commands/unlock  (QoS 1): %s\n",
                  unlockSub ? "OK" : "FAIL");

    // Publish an online heartbeat immediately so the Go gateway and
    // MQTT Explorer know the device is alive.
    _client.publish(
        "robot/status/heartbeat",
        "{\"source\":\"esp32\",\"status\":\"online\"}",
        false  // not retained
    );
}

void MqttManager::_resetBackoff() {
    _backoffMs = MQTT_BACKOFF_BASE_MS;
}

void MqttManager::_advanceBackoff() {
    // Double the backoff interval, capped at MQTT_BACKOFF_MAX_MS.
    // Sequence: 2s → 4s → 8s → 16s → 32s → 60s (cap) → 60s → ...
    _backoffMs = min(_backoffMs * 2, MQTT_BACKOFF_MAX_MS);
}

void MqttManager::_setState(ConnectionState next) {
    if (next == _state) return;  // No-op for same-state transitions
    Serial.printf("[STATE] %s → %s\n",
                  connectionStateName(_state),
                  connectionStateName(next));
    _state = next;
}

// =============================================================================
// Static callback trampoline
// PubSubClient requires a plain function pointer. We bridge it to the
// instance member via the static _instance pointer set in the constructor.
// This is safe for single-instance firmware — no multi-device concern here.
// =============================================================================
void MqttManager::_staticCallback(char* topic, uint8_t* payload, unsigned int len) {
    if (_instance != nullptr && _instance->_userCallback) {
        _instance->_userCallback(topic, payload, len);
    }
}

// =============================================================================
// connectionStateName() — diagnostic helper
// =============================================================================
const char* connectionStateName(ConnectionState s) {
    switch (s) {
        case ConnectionState::BOOT:             return "BOOT";
        case ConnectionState::WIFI_CONNECTING:  return "WIFI_CONNECTING";
        case ConnectionState::WIFI_CONNECTED:   return "WIFI_CONNECTED";
        case ConnectionState::MQTT_CONNECTING:  return "MQTT_CONNECTING";
        case ConnectionState::MQTT_CONNECTED:   return "MQTT_CONNECTED";
        case ConnectionState::WIFI_LOST:        return "WIFI_LOST";
        case ConnectionState::MQTT_LOST:        return "MQTT_LOST";
        default:                                return "UNKNOWN";
    }
}
