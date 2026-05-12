// =============================================================================
// src/mqtt_manager.h
//
// UnBot Delivery — ESP32 MQTT Connection Manager (Header)
// -----------------------------------------------------------------------------
// FIXES APPLIED (v2.1):
//   FIX 1 — Removed all single-quote digit separators (e.g. 15'000 → 15000).
//            The ESP32 Arduino toolchain's GCC version does not support C++14
//            digit separators in all configurations.
//   FIX 2 — All ConnectionState enum values prefixed with CS_ to avoid the
//            macro collision with PubSubClient's #define MQTT_CONNECTED 0.
//            Affected values: CS_BOOT, CS_WIFI_CONNECTING, CS_WIFI_CONNECTED,
//            CS_MQTT_CONNECTING, CS_MQTT_CONNECTED, CS_WIFI_LOST, CS_MQTT_LOST.
//   FIX 3 — Added missing private declarations for _startWifi() and
//            _attemptMqttConnect() which were implemented in the .cpp but
//            absent from the class definition, causing linker errors.
//
// RESPONSIBILITIES:
//   1. Owns both the WiFiClient and PubSubClient objects — no raw network
//      handles leak into main.cpp.
//   2. Manages the full connection state machine:
//        CS_BOOT → CS_WIFI_CONNECTING → CS_WIFI_CONNECTED →
//        CS_MQTT_CONNECTING → CS_MQTT_CONNECTED → (steady state)
//      with re-entry into CS_WIFI_CONNECTING on any network drop.
//   3. Implements exponential backoff for both Wi-Fi and MQTT reconnections
//      using millis() — never blocks the Arduino loop().
//   4. Exposes a single tick() method that main.cpp calls every loop
//      iteration. All state transitions and client.loop() calls happen inside.
//   5. Exposes publish() for outbound messages (heartbeat, status).
//   6. Accepts a message callback at construction time so main.cpp can
//      register its business logic handler without coupling to this class.
//
// THREAD / TASK SAFETY NOTE:
//   Arduino-framework ESP32 runs the sketch on Core 1. PubSubClient's
//   internal callback fires synchronously inside client.loop() on the same
//   core. There are no FreeRTOS tasks here — no mutex needed for the MQTT
//   callback. If you later move Wi-Fi to a background task, add a
//   portMUX_TYPE spinlock around _client.loop().
//
// DEPENDENCIES (platformio.ini):
//   lib_deps =
//     knolleary/PubSubClient @ ^2.8
//     bblanchon/ArduinoJson  @ ^7.0
// =============================================================================

#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <PubSubClient.h>

// -----------------------------------------------------------------------------
// Tuneable timing constants
// All durations are in milliseconds so they can be compared directly against
// millis() without unit confusion.
//
// FIX 1: Single-quote digit separators removed throughout this file.
// -----------------------------------------------------------------------------

// Wi-Fi: initial wait before declaring a connect attempt failed.
static constexpr uint32_t WIFI_CONNECT_TIMEOUT_MS = 15000;

// MQTT backoff: starts at BASE, doubles each attempt, caps at MAX.
static constexpr uint32_t MQTT_BACKOFF_BASE_MS    =  2000;
static constexpr uint32_t MQTT_BACKOFF_MAX_MS     = 60000;

// How often to call client.loop() at minimum (keep-alive granularity).
// PubSubClient's default keep-alive is 15 s; polling every 50 ms is safe.
static constexpr uint32_t MQTT_LOOP_INTERVAL_MS   =    50;

// -----------------------------------------------------------------------------
// Type alias for the application-level message callback.
// Signature matches PubSubClient's MQTT_CALLBACK_SIGNATURE:
//   void callback(char* topic, byte* payload, unsigned int length)
// main.cpp passes its handler here so MqttManager stays business-logic-free.
// -----------------------------------------------------------------------------
using MqttMessageCallback = std::function<void(char*, uint8_t*, unsigned int)>;

// -----------------------------------------------------------------------------
// Connection state machine
//
// FIX 2: All enum values prefixed with CS_ (ConnectionState_) to prevent
// collision with PubSubClient's preprocessor macros. PubSubClient defines:
//   #define MQTT_CONNECTED       0
//   #define MQTT_CONNECT_FAILED -4
//   #define MQTT_DISCONNECTED   -1
//   ... and others.
// Without the CS_ prefix, the C preprocessor silently replaces matching
// enum value names with integer literals before the compiler sees them,
// producing type errors and broken switch() behaviour that is very hard
// to diagnose because the error messages reference integers, not names.
//
// Exposed as a public enum so main.cpp can query state() for diagnostics
// without coupling to internal implementation details.
// -----------------------------------------------------------------------------
enum class ConnectionState : uint8_t {
    CS_BOOT,             // Initial power-on, nothing attempted yet.
    CS_WIFI_CONNECTING,  // WiFi.begin() called; waiting for WL_CONNECTED.
    CS_WIFI_CONNECTED,   // Wi-Fi up; will attempt MQTT connect next tick.
    CS_MQTT_CONNECTING,  // client.connect() called; waiting for result.
    CS_MQTT_CONNECTED,   // Steady state. client.loop() runs every tick.
    CS_WIFI_LOST,        // Wi-Fi dropped mid-session; will reconnect.
    CS_MQTT_LOST,        // MQTT dropped but Wi-Fi still up; will reconnect.
};

// Helper: human-readable state name for Serial diagnostics.
// Defined in mqtt_manager.cpp; declared here so main.cpp can call it too.
const char* connectionStateName(ConnectionState s);

// =============================================================================
// MqttManager
// =============================================================================
class MqttManager {
public:
    // -------------------------------------------------------------------------
    // Constructor
    //   ssid, password — Wi-Fi credentials from secrets.h
    //   brokerIp       — Mosquitto broker IP (plain char* avoids String heap)
    //   brokerPort     — typically 1883
    //   clientId       — unique per device; see MQTT_CLIENT_ID in secrets.h
    //   mqttUser       — broker username (M2M credential)
    //   mqttPass       — broker password (M2M credential)
    //   callback       — application message handler; called inside tick()
    // -------------------------------------------------------------------------
    MqttManager(
        const char*         ssid,
        const char*         password,
        const char*         brokerIp,
        uint16_t            brokerPort,
        const char*         clientId,
        const char*         mqttUser,
        const char*         mqttPass,
        MqttMessageCallback callback
    );

    // -------------------------------------------------------------------------
    // begin()
    // Call once from setup(). Configures the WiFi mode, disables modem sleep
    // for deterministic latency, and starts the first Wi-Fi connection attempt.
    // Does NOT block.
    // -------------------------------------------------------------------------
    void begin();

    // -------------------------------------------------------------------------
    // tick()
    // Call every iteration of loop() with no arguments.
    // Internally: advances the state machine, drives client.loop(),
    // and handles reconnection with backoff. Never calls delay().
    // -------------------------------------------------------------------------
    void tick();

    // -------------------------------------------------------------------------
    // publish()
    // Sends a message on the given topic at QoS 1.
    // Returns true if the broker ACK'd the PUBLISH packet.
    // Returns false and logs a warning if not currently in CS_MQTT_CONNECTED.
    // -------------------------------------------------------------------------
    bool publish(const char* topic, const char* payload, bool retained = false);

    // -------------------------------------------------------------------------
    // isConnected()
    // True only when the state machine is in CS_MQTT_CONNECTED.
    // Use this guard before calling publish() from main.cpp.
    // -------------------------------------------------------------------------
    bool isConnected() const;

    // -------------------------------------------------------------------------
    // state()
    // Returns the current ConnectionState for diagnostic / display use.
    // -------------------------------------------------------------------------
    ConnectionState state() const { return _state; }

    // -------------------------------------------------------------------------
    // subscribe()
    // Subscribes to a topic at QoS 1. Internal use: called inside
    // _onMqttConnect() for all mandatory topics. Exposed publicly so main.cpp
    // can add optional topics at runtime after CS_MQTT_CONNECTED is reached.
    // -------------------------------------------------------------------------
    bool subscribe(const char* topic, uint8_t qos = 1);

private:
    // ── Credentials ───────────────────────────────────────────────────────────
    // Stored as const char* pointing to string literals in flash.
    // No heap allocation; no String objects.
    const char* _ssid;
    const char* _password;
    const char* _brokerIp;
    uint16_t    _brokerPort;
    const char* _clientId;
    const char* _mqttUser;
    const char* _mqttPass;

    // ── Network objects ───────────────────────────────────────────────────────
    WiFiClient   _wifiClient;  // Plain TCP. V3.0: replace with WiFiClientSecure.
    PubSubClient _client;      // MQTT client; holds a reference to _wifiClient.

    // ── Application callback ──────────────────────────────────────────────────
    MqttMessageCallback _userCallback;

    // ── State machine ─────────────────────────────────────────────────────────
    ConnectionState _state;

    // ── Timing / backoff ──────────────────────────────────────────────────────
    uint32_t _backoffMs;      // Current MQTT reconnect backoff interval.
    uint32_t _lastAttemptMs;  // millis() at the last MQTT connect attempt.
    uint32_t _lastLoopMs;     // millis() at the last client.loop() call.
    uint32_t _wifiStartMs;    // millis() when the current WiFi.begin() was called.

    // ── State handler methods ─────────────────────────────────────────────────
    // One method per ConnectionState, called from tick().
    void _handleBoot();
    void _handleWifiConnecting();
    void _handleWifiConnected();
    void _handleMqttConnecting();
    void _handleMqttConnected();
    void _handleWifiLost();
    void _handleMqttLost();

    // ── Connection action methods ─────────────────────────────────────────────
    // FIX 3: These were implemented in mqtt_manager.cpp but missing from the
    // class declaration here, producing "was not declared in this scope" errors.

    // Calls WiFi.begin() with stored credentials and records _wifiStartMs.
    // Called from _handleBoot(), _handleWifiConnecting() (on timeout retry),
    // and _handleWifiLost().
    void _startWifi();

    // Calls _client.connect() with credentials and Last Will payload.
    // Records _lastAttemptMs. Called from _handleWifiConnected(),
    // _handleMqttConnecting() (on backoff retry), and _handleMqttLost().
    void _attemptMqttConnect();

    // ── Shared utility methods ────────────────────────────────────────────────

    // Re-subscribes to all mandatory topics and publishes an online heartbeat.
    // MUST be called on every successful client.connect() — PubSubClient does
    // not persist subscriptions across disconnects.
    void _onMqttConnect();

    // Resets _backoffMs to MQTT_BACKOFF_BASE_MS after a successful connect.
    void _resetBackoff();

    // Doubles _backoffMs up to MQTT_BACKOFF_MAX_MS after a failed attempt.
    void _advanceBackoff();

    // Transitions _state to `next` with a Serial log line. No-op if already
    // in the target state, preventing duplicate log spam on repeated ticks.
    void _setState(ConnectionState next);

    // ── Static trampoline ─────────────────────────────────────────────────────
    // PubSubClient::setCallback() requires a plain C function pointer.
    // _staticCallback holds a pointer to the singleton MqttManager instance
    // and forwards calls to _userCallback. Safe because this firmware runs
    // exactly one MqttManager for the lifetime of the process.
    static MqttManager* _instance;
    static void _staticCallback(char* topic, uint8_t* payload, unsigned int len);
};