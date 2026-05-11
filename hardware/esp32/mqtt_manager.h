// =============================================================================
// src/mqtt_manager.h
//
// UnBot Delivery — ESP32 MQTT Connection Manager (Header)
// -----------------------------------------------------------------------------
// RESPONSIBILITIES:
//   1. Owns both the WiFiClient and PubSubClient objects — no raw network
//      handles leak into main.cpp.
//   2. Manages the full connection state machine:
//        BOOT → WIFI_CONNECTING → WIFI_CONNECTED →
//        MQTT_CONNECTING → MQTT_CONNECTED → (steady state)
//      with re-entry into WIFI_CONNECTING on any network drop.
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
// -----------------------------------------------------------------------------

// Wi-Fi: initial wait before declaring a connect attempt failed.
static constexpr uint32_t WIFI_CONNECT_TIMEOUT_MS  = 15'000;

// MQTT backoff: starts at BASE, doubles each attempt, caps at MAX.
static constexpr uint32_t MQTT_BACKOFF_BASE_MS      =  2'000;
static constexpr uint32_t MQTT_BACKOFF_MAX_MS       = 60'000;

// How often to call client.loop() at minimum (keep-alive granularity).
// PubSubClient's default keep-alive is 15 s; polling every 50 ms is safe.
static constexpr uint32_t MQTT_LOOP_INTERVAL_MS     =     50;

// -----------------------------------------------------------------------------
// Type alias for the application-level message callback.
// Signature matches PubSubClient's MQTT_CALLBACK_SIGNATURE:
//   void callback(char* topic, byte* payload, unsigned int length)
// main.cpp passes its handler here so MqttManager stays business-logic-free.
// -----------------------------------------------------------------------------
using MqttMessageCallback = std::function<void(char*, uint8_t*, unsigned int)>;

// -----------------------------------------------------------------------------
// Connection state machine
// Exposed as a public enum so main.cpp can query it for diagnostic output
// without coupling to internal implementation details.
// -----------------------------------------------------------------------------
enum class ConnectionState : uint8_t {
    BOOT,             // Initial power-on, nothing attempted yet.
    WIFI_CONNECTING,  // WiFi.begin() called; waiting for WL_CONNECTED.
    WIFI_CONNECTED,   // Wi-Fi up; will attempt MQTT connect next tick.
    MQTT_CONNECTING,  // client.connect() called; waiting for result.
    MQTT_CONNECTED,   // Steady state. client.loop() runs every tick.
    WIFI_LOST,        // Wi-Fi dropped mid-session; will reconnect.
    MQTT_LOST,        // MQTT dropped but Wi-Fi still up; will reconnect.
};

// Helper: human-readable state name for Serial diagnostics.
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
        const char* ssid,
        const char* password,
        const char* brokerIp,
        uint16_t    brokerPort,
        const char* clientId,
        const char* mqttUser,
        const char* mqttPass,
        MqttMessageCallback callback
    );

    // -------------------------------------------------------------------------
    // begin()
    // Call once from setup(). Configures Serial logging and starts the
    // Wi-Fi connection attempt. Does NOT block.
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
    // Sends a message on the given topic. Returns true if the broker ACK'd
    // (QoS 1 semantics via PubSubClient — note PubSubClient QoS 1 does not
    // guarantee delivery to subscribers, only broker receipt).
    // Returns false if not currently connected.
    // -------------------------------------------------------------------------
    bool publish(const char* topic, const char* payload, bool retained = false);

    // -------------------------------------------------------------------------
    // isConnected()
    // True only when the state machine is in MQTT_CONNECTED.
    // Use this guard before calling publish() from main.cpp.
    // -------------------------------------------------------------------------
    bool isConnected() const;

    // -------------------------------------------------------------------------
    // state()
    // Returns the current ConnectionState for diagnostic use.
    // -------------------------------------------------------------------------
    ConnectionState state() const { return _state; }

    // -------------------------------------------------------------------------
    // subscribe()
    // Subscribes to a topic at QoS 1. Call from the onConnect path (already
    // handled internally), but exposed so main.cpp can add extra topics at
    // runtime after the manager reaches MQTT_CONNECTED.
    // -------------------------------------------------------------------------
    bool subscribe(const char* topic, uint8_t qos = 1);

private:
    // Credentials — stored as const char* pointing to string literals in
    // flash (PROGMEM-eligible). No heap allocation for credential strings.
    const char* _ssid;
    const char* _password;
    const char* _brokerIp;
    uint16_t    _brokerPort;
    const char* _clientId;
    const char* _mqttUser;
    const char* _mqttPass;

    // Network objects
    WiFiClient    _wifiClient;   // Plain TCP — V3.0 replaces with WiFiClientSecure
    PubSubClient  _client;       // MQTT client; owns _wifiClient reference

    // Application callback — stored and forwarded to PubSubClient
    MqttMessageCallback _userCallback;

    // State machine
    ConnectionState _state;

    // Backoff state
    uint32_t _backoffMs;          // Current backoff interval (doubles each retry)
    uint32_t _lastAttemptMs;      // millis() at last connection attempt
    uint32_t _lastLoopMs;         // millis() at last client.loop() call
    uint32_t _wifiStartMs;        // millis() when current WiFi.begin() was called

    // ── Private helpers ──────────────────────────────────────────────────────

    // Advance state machine for each state.
    void _handleBoot();
    void _handleWifiConnecting();
    void _handleWifiConnected();
    void _handleMqttConnecting();
    void _handleMqttConnected();
    void _handleWifiLost();
    void _handleMqttLost();

    // Called on every successful MQTT connect to re-subscribe to all topics.
    // PubSubClient drops all subscriptions on disconnect — must re-subscribe
    // inside onConnect, not once at startup.
    void _onMqttConnect();

    // Reset backoff to base value (called on successful connect).
    void _resetBackoff();

    // Advance backoff to next interval (called on failed connect attempt).
    void _advanceBackoff();

    // Transition to a new state with Serial logging.
    void _setState(ConnectionState next);

    // Static trampoline: PubSubClient requires a plain function pointer but we
    // need to forward to a member. We store a static self-pointer and jump.
    static MqttManager* _instance;
    static void _staticCallback(char* topic, uint8_t* payload, unsigned int len);
};
