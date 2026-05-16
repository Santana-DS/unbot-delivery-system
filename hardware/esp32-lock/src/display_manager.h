// =============================================================================
// src/display_manager.h
//
// UnBot Delivery — OLED Display + QR Code Subsystem (v3.0)
// -----------------------------------------------------------------------------
// RESPONSIBILITIES:
//   Owns the Adafruit_SSD1306 driver object and every rendering function.
//   main.cpp never touches the display directly — it calls this API only.
//
// HARDWARE:
//   SSD1306 128×64 OLED over I2C.
//   ESP32 default I2C pins: SDA = GPIO 21, SCL = GPIO 22.
//   I2C address 0x3C is the standard for 128×64 modules; 0x3D for 128×32.
//   No reset pin needed when the module's RST is wired to ESP32 EN (common).
//
// QR CODE MATH (version 1, ECC level M):
//   Matrix size   : 21 × 21 modules
//   Buffer size   : qrcode_getBufferSize(1) = 70 bytes  (stack, not heap)
//   Pixel scale   : 3  →  21 × 3 = 63 px per side
//   Display        : 128 × 64
//   Horizontal offset: (128 - 63) / 2 = 32 px  → centered
//   Vertical offset  : (64  - 63) / 2 =  0 px  → flush top (1px margin at bottom)
//
//   A 4-digit OTP ("0000"–"9999") encodes comfortably at QR version 1 / ECC M.
//   If you ever encode a full URL, bump QR_VERSION to 3 and recheck the scale.
//
// RAM BUDGET:
//   QR uint8_t buffer : 70 B   (stack-local in showQrCode)
//   SSD1306 framebuf  : 1024 B (heap, allocated once in begin())
//   No dynamic strings, no String objects anywhere in this file.
// =============================================================================

#pragma once

#include <stdint.h>
#include <stdbool.h>

// =============================================================================
// Hardware constants — change only these if you rewire the board.
// =============================================================================

// I2C pins — ESP32 hardware defaults. Change if you use custom I2C bus.
static constexpr uint8_t OLED_SDA_PIN = 21;
static constexpr uint8_t OLED_SCL_PIN = 22;

// I2C address: 0x3C for 128×64, 0x3D for some 128×32 variants.
static constexpr uint8_t OLED_I2C_ADDR = 0x3C;

// OLED dimensions in pixels.
static constexpr uint8_t OLED_WIDTH  = 128;
static constexpr uint8_t OLED_HEIGHT = 64;

// QR Code generation parameters.
// Version 1 = 21×21 modules. Supports up to 16 alphanumeric chars at ECC M.
// A 4-digit numeric OTP fits with headroom.
static constexpr uint8_t QR_VERSION    = 1;
static constexpr uint8_t QR_ECC_LEVEL  = 1;  // ECC_LOW=0, ECC_MEDIUM=1, ECC_QUARTILE=2, ECC_HIGH=3
static constexpr uint8_t QR_MODULE_PX  = 3;  // Pixel scale per module (3 → 63×63 px)

// Derived offsets — compile-time constants, no runtime math.
// 21 modules × 3 px/module = 63 px
static constexpr uint8_t QR_RENDER_PX  = 21 * QR_MODULE_PX;  // 63
static constexpr uint8_t QR_OFFSET_X   = (OLED_WIDTH  - QR_RENDER_PX) / 2;  // 32
static constexpr uint8_t QR_OFFSET_Y   = (OLED_HEIGHT - QR_RENDER_PX) / 2;  //  0

// =============================================================================
// DisplayManager
// =============================================================================
class DisplayManager {
public:
    // -------------------------------------------------------------------------
    // begin()
    // Initialises the I2C bus on SDA/SCL pins and the SSD1306 driver.
    // Must be called once from setup() before any other method.
    // Returns false if the display is not detected on the I2C bus — allows
    // main.cpp to log the fault and continue (robot can still operate without
    // the display; unlock still works via OTP validation).
    // -------------------------------------------------------------------------
    bool begin();

    // -------------------------------------------------------------------------
    // showQrCode(otp)
    // Generates a QR Code matrix for the 4-char OTP string and renders it
    // centered on the display.
    //
    //   otp — must be exactly 4 ASCII digit characters ("0000"–"9999").
    //          The caller (main.cpp MQTT callback) is responsible for
    //          validating the length before calling this method.
    //
    // Rendering pipeline:
    //   1. qrcode_initBytes()  — fills a 70-byte stack buffer with the matrix.
    //   2. display.clearDisplay()
    //   3. Nested loop over 21×21 modules → drawPixel() for each dark module,
    //      scaled ×3 (3×3 filled rectangle per module).
    //   4. Overlay status text: "CÓDIGO DO PEDIDO" (top) + orderId (bottom).
    //      If orderId is empty the overlay lines are skipped.
    //   5. display.display() — pushes the 1KB framebuffer to the SSD1306.
    //
    // Stack usage: ~70 bytes for the QR buffer + qrcode_t struct (~8 bytes).
    // No heap allocation.
    // -------------------------------------------------------------------------
    void showQrCode(const char* otp, const char* orderId = "");

    // -------------------------------------------------------------------------
    // showUnlockSuccess(orderId)
    // Clears the screen and renders the delivery-complete UI:
    //   - Large ✓ icon (drawn as concentric rectangles — no bitmap needed).
    //   - "ABERTO!" label.
    //   - orderId in small text at the bottom.
    // Called immediately on receiving robot/commands/unlock, before the GPIO
    // actuator fires, so the customer sees feedback instantly.
    // -------------------------------------------------------------------------
    void showUnlockSuccess(const char* orderId = "");

    // -------------------------------------------------------------------------
    // showBooting()
    // Startup screen: UnBot logo text + "Conectando..." status.
    // Replaces the blank screen during the Wi-Fi/MQTT connection phase.
    // -------------------------------------------------------------------------
    void showBooting();

    // -------------------------------------------------------------------------
    // showConnected()
    // Replaces the booting screen once MQTT reaches CS_MQTT_CONNECTED.
    // Displays "UnBot Delivery" + "Aguardando pedido..." in idle state.
    // -------------------------------------------------------------------------
    void showConnected();

    // -------------------------------------------------------------------------
    // showError(msg)
    // Renders a one-line error string centred on the display.
    // Used for I2C initialisation failure or JSON parse errors.
    // msg is truncated to 21 chars (SSD1306 default font width at textSize 1).
    // -------------------------------------------------------------------------
    void showError(const char* msg);

    // -------------------------------------------------------------------------
    // isReady()
    // Returns true if begin() succeeded. Guards all render calls from main.cpp.
    // -------------------------------------------------------------------------
    bool isReady() const { return _ready; }

private:
    bool _ready = false;

    // Internal helper: draws a filled rectangle of QR_MODULE_PX × QR_MODULE_PX
    // pixels at (x0, y0) in the framebuffer. Inlined for the hot render loop.
    void _drawModule(uint8_t col, uint8_t row);

    // Internal helper: centre-aligns a string on a given display row (pixel y).
    // Uses font size 1 (6px wide per char) to compute the x offset.
    void _drawCentredText(const char* text, uint8_t y, uint8_t textSize = 1);
};
