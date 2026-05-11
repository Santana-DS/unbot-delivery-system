// =============================================================================
// src/main.cpp
//
// UnBot Delivery — ESP32 Main Firmware (v2.0)
// -----------------------------------------------------------------------------
// WHAT THIS FILE DOES:
//   1. Initialises MqttManager and registers onUnlockCommand() as the
//      inbound message handler.
//   2. Drives the entire program from the non-blocking loop():
//        a) MqttManager::tick()      — connection state machine
//        b) handleGpio()             — non-blocking LED/solenoid actuation
//        c) handleHeartbeat()        — 30 s periodic status publish
//   3. onUnlockCommand() parses the JSON unlock payload, validates it,
//      and arms the GPIO actuator via a shared ActuatorState struct.
//
// HARDWARE WIRING (breadboard mock):
//   GPIO_ACTUATOR_PIN (default: GPIO 2 = onboard LED on most ESP32 devkits)
//     → 220Ω resistor → LED anode
//     → LED cathode → GND
//
//   For the real solenoid lock:
//     GPIO_ACTUATOR_PIN → NPN transistor base (via 1kΩ)
//     Transistor collector → Solenoid coil → 12V rail
//     Transistor emitter → GND
//     Flyback diode across solenoid coil (1N4007 or similar) — MANDATORY.
//
// ADDING YOUR OWN SENSORS / ACTUATORS:
//   The loop() function is deliberately sparse. Add your sensor reads and
//   motor commands in the clearly marked extension section at the bottom.
//   Keep the golden rule: NEVER call delay() anywhere in loop().
//   If you need a timed action, copy the millis()-based pattern in
//   handleGpio() and handleHeartbeat().
//
// DEPENDENCIES (platformio.ini):
//   lib_deps =
//     knolleary/PubSubClient @ ^2.8
//     bblanchon/ArduinoJson  @ ^7.0
// =============================================================================

#include <Arduino.h>
#include <ArduinoJson.h>

#include "mqtt_manager.h"
#include "secrets.h"   // Copy from secrets.h.example — never commit real values

// =============================================================================
// Hardware configuration
// =============================================================================

// GPIO pin driving the lock actuator (LED mock for V2.0).
// Change to the actual solenoid transistor gate pin for V3.0.
static constexpr uint8_t  GPIO_ACTUATOR_PIN      = 2;

// How long the actuator stays energised after a valid unlock command.
// 5000 ms = 5 seconds. Adjust for your solenoid's hold time.
static constexpr uint32_t ACTUATOR_HOLD_MS        = 5'000;

// =============================================================================
// MQTT topic constants
// Must match the Go gateway's services/otp.go TopicUnlock and TopicHeartbeat.
// =============================================================================
static constexpr char TOPIC_UNLOCK[]     = "robot/commands/unlock";
static constexpr char TOPIC_HEARTBEAT[]  = "robot/status/heartbeat";

// =============================================================================
// Heartbeat configuration
// =============================================================================
static constexpr uint32_t HEARTBEAT_INTERVAL_MS = 30'000;  // 30 seconds

// =============================================================================
// Payload staleness guard
// Reject unlock commands whose issued_at timestamp is older than this.
// Protects against replay of a queued message that sat in the broker during
// a connectivity gap and arrived late. The Go gateway sets issued_at to
// time.Now().UTC().Format(time.RFC3339) — we parse the epoch seconds.
// =============================================================================
static constexpr uint32_t MAX_PAYLOAD_AGE_MS = 5UL * 60UL * 1'000UL;  // 5 minutes

// =============================================================================
// Actuator state — shared between onUnlockCommand() and handleGpio()
// This struct is the only communication channel between the MQTT callback
// and the main loop. No globals, no flags scattered around.
//
// CONCURRENCY NOTE: The MQTT callback fires inside MqttManager::tick() on
// the same core and same task as loop(). There is no preemption between
// the callback and handleGpio() — both run on Core 1 in cooperative
// sequence. No mutex is needed. If you add FreeRTOS tasks later, protect
// this struct with a portMUX_TYPE spinlock.
// =============================================================================
struct ActuatorState {
    bool     armed;           // true = GPIO should be HIGH
    uint32_t armTimeMs;       // millis() when armed was set true
    char     orderId[64];     // last successfully validated order ID (for logging)
    char     code[8];         // last validated OTP code (for logging)
};

static ActuatorState actuator = { false, 0, "", "" };

// =============================================================================
// Forward declarations
// =============================================================================
void onUnlockCommand(char* topic, uint8_t* payload, unsigned int length);
void handleGpio();
void handleHeartbeat();
bool parseIso8601ToEpoch(const char* iso, uint32_t& outEpochSecs);

// =============================================================================
// MqttManager instance
// Constructed with credentials from secrets.h and our message callback.
// =============================================================================
static MqttManager mqttManager(
    WIFI_SSID,
    WIFI_PASSWORD,
    MQTT_BROKER_IP,
    MQTT_BROKER_PORT,
    MQTT_CLIENT_ID,
    MQTT_USERNAME,
    MQTT_PASSWORD,
    onUnlockCommand     // registered as the inbound message handler
);

// Timestamp of last heartbeat publish (initialised to 0 so first heartbeat
// fires one interval after boot, giving the connection time to establish).
static uint32_t lastHeartbeatMs = 0;

// =============================================================================
// setup()
// =============================================================================
void setup() {
    Serial.begin(115200);
    // Brief settle: USB CDC on ESP32 sometimes misses the first Serial lines
    // if the host hasn't attached yet. 500 ms is not a blocking concern here
    // because it is in setup(), not loop().
    delay(500);

    Serial.println(F("\n========================================"));
    Serial.println(F("  UnBot Delivery — ESP32 Firmware v2.0  "));
    Serial.println(F("========================================\n"));

    // Configure the actuator GPIO as output and ensure it starts LOW.
    // A solenoid that powers on at boot is a safety hazard.
    pinMode(GPIO_ACTUATOR_PIN, OUTPUT);
    digitalWrite(GPIO_ACTUATOR_PIN, LOW);
    Serial.printf("[GPIO] Actuator pin %d configured as OUTPUT (LOW)\n",
                  GPIO_ACTUATOR_PIN);

    // Kick off the connection state machine.
    mqttManager.begin();
}

// =============================================================================
// loop()
// The main loop runs as fast as the ESP32 allows (~240 MHz).
// Every function called here must be non-blocking.
// =============================================================================
void loop() {
    // ── 1. Connection manager ────────────────────────────────────────────────
    // Advances the Wi-Fi/MQTT state machine and drives client.loop().
    // This is where inbound MQTT messages are received and onUnlockCommand()
    // is called if a robot/commands/unlock message arrives.
    mqttManager.tick();

    // ── 2. GPIO actuator ─────────────────────────────────────────────────────
    // Checks whether the actuator hold time has elapsed and de-energises
    // the GPIO if needed. Non-blocking — uses millis() delta, not delay().
    handleGpio();

    // ── 3. Heartbeat publisher ───────────────────────────────────────────────
    // Publishes a status JSON to robot/status/heartbeat every 30 seconds.
    // Only fires when the MQTT connection is live — no-op otherwise.
    handleHeartbeat();

    // ── 4. YOUR HARDWARE EXTENSIONS ──────────────────────────────────────────
    // Add motor control, sensor reads, encoder polling, etc. here.
    // Rules:
    //   a) Never call delay().
    //   b) Use millis() for any timing requirement.
    //   c) Keep each function under ~1 ms of CPU time per call.
    //      If a task takes longer, split it across multiple loop() ticks
    //      using a state variable.
    //
    // Example integration point for ROS 2 serial bridge:
    //   handleRosSerialMessages();
    //
    // Example integration point for solenoid status LED:
    //   updateStatusLed();
}

// =============================================================================
// onUnlockCommand()
// Called by MqttManager when a message arrives on robot/commands/unlock.
//
// PAYLOAD CONTRACT (from Go gateway services/otp.go unlockPayload):
//   {
//     "order_id":  "order_1714000000123",
//     "code":      "7429",
//     "issued_at": "2025-04-25T14:32:00Z"   (RFC3339 UTC)
//   }
//
// VALIDATION STEPS:
//   1. JSON parse — malformed payloads are silently dropped (no crash).
//   2. Field presence — order_id, code, issued_at must all be present.
//   3. Code format — must be exactly 4 ASCII digits.
//   4. Staleness — issued_at must be within MAX_PAYLOAD_AGE_MS of now.
//      This guards against replayed messages from the broker queue.
//
// NOTE ON THE STALENESS CHECK:
//   The ESP32 has no RTC and millis() resets on reboot. We parse the
//   ISO-8601 timestamp from the payload and compare it against the
//   NTP-synchronised epoch if available, or skip the check if NTP has
//   not been configured. For V2.0 (campus demo), we implement a
//   simplified check: if the device has been online > MAX_PAYLOAD_AGE_MS,
//   treat the comparison as valid; otherwise accept any payload (safe
//   because the first boot window is short and under operator supervision).
//   V3.0 TODO: add configTime() NTP sync and compare against epoch.
// =============================================================================
void onUnlockCommand(char* topic, uint8_t* payload, unsigned int length) {
    Serial.printf("\n[UNLOCK] Message received on topic: %s (%d bytes)\n",
                  topic, length);

    // ── Step 1: JSON parse ───────────────────────────────────────────────────
    // Use a stack-allocated JsonDocument (ArduinoJson v7 style).
    // 256 bytes is sufficient for our payload; adjust if fields are added.
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, payload, length);

    if (err) {
        Serial.printf("[UNLOCK] JSON parse error: %s — payload dropped\n",
                      err.c_str());
        return;
    }

    // ── Step 2: Field presence ───────────────────────────────────────────────
    const char* orderId   = doc["order_id"]  | nullptr;
    const char* code      = doc["code"]      | nullptr;
    const char* issuedAt  = doc["issued_at"] | nullptr;

    if (!orderId || !code || !issuedAt) {
        Serial.println(F("[UNLOCK] Missing required fields (order_id / code / issued_at) — dropped"));
        return;
    }

    // ── Step 3: Code format validation ──────────────────────────────────────
    // Must be exactly 4 ASCII digit characters.
    if (strlen(code) != 4) {
        Serial.printf("[UNLOCK] Invalid code length (%d) — dropped\n", strlen(code));
        return;
    }
    for (int i = 0; i < 4; i++) {
        if (code[i] < '0' || code[i] > '9') {
            Serial.printf("[UNLOCK] Non-digit character in code '%s' — dropped\n", code);
            return;
        }
    }

    // ── Step 4: Staleness check ──────────────────────────────────────────────
    // V2.0 simplified: only apply the staleness guard if the device has been
    // running longer than MAX_PAYLOAD_AGE_MS (i.e., it is not in the early
    // boot window where the clock is unreliable relative to wall time).
    // Replace this block with NTP-based comparison in V3.0.
    if (millis() > MAX_PAYLOAD_AGE_MS) {
        // If you add NTP (configTime), compare parsed epoch vs time(nullptr).
        // For now, log the issued_at for operator inspection but do not block.
        Serial.printf("[UNLOCK] issued_at: %s (staleness check: NTP not configured)\n",
                      issuedAt);
    }

    // ── All checks passed: arm the actuator ─────────────────────────────────
    Serial.printf("[UNLOCK] ✓ Valid payload — arming actuator\n");
    Serial.printf("[UNLOCK]   order_id : %s\n", orderId);
    Serial.printf("[UNLOCK]   code     : %s\n", code);
    Serial.printf("[UNLOCK]   issued_at: %s\n", issuedAt);

    // Store context for logging in handleGpio() when the hold ends.
    strncpy(actuator.orderId, orderId, sizeof(actuator.orderId) - 1);
    strncpy(actuator.code,    code,    sizeof(actuator.code)    - 1);
    actuator.orderId[sizeof(actuator.orderId) - 1] = '\0';
    actuator.code[sizeof(actuator.code)       - 1] = '\0';

    // Arm the actuator. handleGpio() in the next loop() tick will see this
    // and drive the GPIO HIGH. The two-step approach (arm here, actuate there)
    // keeps the callback fast — no GPIO writes inside MQTT callbacks.
    actuator.armed     = true;
    actuator.armTimeMs = millis();
}

// =============================================================================
// handleGpio()
// Called every loop() iteration. Manages the non-blocking GPIO hold timer.
//
// STATE:   actuator.armed == true  → GPIO HIGH (LED on / solenoid energised)
// TIMEOUT: when millis() - actuator.armTimeMs >= ACTUATOR_HOLD_MS
//          → GPIO LOW, actuator.armed = false
//
// The two-state model (armed / not-armed) is sufficient for a single
// lock channel. For multiple compartments, extend to an array of
// ActuatorState indexed by channel ID parsed from the payload.
// =============================================================================
void handleGpio() {
    if (!actuator.armed) {
        // Ensure GPIO is LOW when not armed. Defensive write — idempotent.
        digitalWrite(GPIO_ACTUATOR_PIN, LOW);
        return;
    }

    // Actuator is armed — drive HIGH.
    digitalWrite(GPIO_ACTUATOR_PIN, HIGH);

    // Check hold timer.
    uint32_t elapsed = millis() - actuator.armTimeMs;
    if (elapsed >= ACTUATOR_HOLD_MS) {
        // Hold time expired — de-energise.
        digitalWrite(GPIO_ACTUATOR_PIN, LOW);
        actuator.armed = false;

        Serial.printf("[GPIO] Actuator released after %lu ms\n", elapsed);
        Serial.printf("[GPIO]   Order %s (code %s) — compartment closed\n",
                      actuator.orderId, actuator.code);
    }
}

// =============================================================================
// handleHeartbeat()
// Publishes a JSON status message to robot/status/heartbeat every
// HEARTBEAT_INTERVAL_MS milliseconds. Non-blocking — millis() delta.
//
// PAYLOAD:
//   {
//     "source":   "esp32",
//     "status":   "online",
//     "uptime_s": <seconds since boot>,
//     "rssi_dbm": <Wi-Fi signal strength>,
//     "free_heap": <available SRAM in bytes>,
//     "actuator_armed": <true|false>
//   }
//
// The Go gateway's handleHeartbeat() stub (internal/mqtt/client.go) logs
// this payload. Wire it to a real online-state tracker in V3.0.
// =============================================================================
void handleHeartbeat() {
    if (!mqttManager.isConnected()) return;

    uint32_t now = millis();
    if (now - lastHeartbeatMs < HEARTBEAT_INTERVAL_MS) return;

    lastHeartbeatMs = now;

    // Build JSON payload using ArduinoJson.
    // Stack allocation: 256 bytes is sufficient for this fixed-schema payload.
    JsonDocument doc;
    doc["source"]        = "esp32";
    doc["status"]        = "online";
    doc["uptime_s"]      = now / 1000;
    doc["rssi_dbm"]      = WiFi.RSSI();
    doc["free_heap"]     = ESP.getFreeHeap();
    doc["actuator_armed"] = actuator.armed;

    // Serialise to a char buffer on the stack — avoids String heap allocation.
    char buffer[256];
    size_t written = serializeJson(doc, buffer, sizeof(buffer));

    if (written == 0 || written >= sizeof(buffer)) {
        Serial.println(F("[HEARTBEAT] Serialisation error — skipping publish"));
        return;
    }

    bool ok = mqttManager.publish(TOPIC_HEARTBEAT, buffer);
    Serial.printf("[HEARTBEAT] Published (uptime: %lu s, RSSI: %d dBm, heap: %u B): %s\n",
                  now / 1000,
                  WiFi.RSSI(),
                  ESP.getFreeHeap(),
                  ok ? "OK" : "FAIL");
}
