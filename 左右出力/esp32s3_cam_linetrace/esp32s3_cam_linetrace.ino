/*
 * ============================================================
 *  ESP32-S3 CAM ライントレース誤差送信
 *  Freenove ESP32-S3 WROVER CAM Board (OV2640)
 * ============================================================
 *  OV2640 QQVGA グレースケール → ROI 二値化 → 黒ピクセル重心算出
 *  → 誤差を UART(Serial1) で UNO R4 WiFi へ送信
 *
 *  送信プロトコル:
 *    "L:<-100..100>\n"   ライン誤差（負=左、正=右、0=中央）
 *    "L:NA\n"            ライン未検出
 *
 *  想定環境: 黒ライン on 白床
 *  白ライン on 黒床の場合は BIN_THRESHOLD を 180 程度に上げるか、
 *  detectLineError() 内の "<=" を ">=" に反転すること。
 *
 *  必要ライブラリ:
 *    - esp_camera.h（Arduino-ESP32 v2.0.14 以降に同梱）
 *    ボードマネージャ: "esp32" by Espressif Systems v2.0.14 以降
 *    ボード選択例: "ESP32S3 Dev Module" または "Freenove ESP32S3 WROOM"
 *
 *  別ボードを使う場合はカメラピン定義を書き換えること（セクション参照）
 * ============================================================
 */

#include "esp_camera.h"

// ============================================================
//  カメラピン定義 ― Freenove ESP32-S3 WROVER CAM Board 用
//  別ボードを使う場合はここを書き換える
// ============================================================
#define PWDN_GPIO_NUM   -1
#define RESET_GPIO_NUM  -1
#define XCLK_GPIO_NUM   15
#define SIOD_GPIO_NUM    4
#define SIOC_GPIO_NUM    5
#define Y9_GPIO_NUM     16
#define Y8_GPIO_NUM     17
#define Y7_GPIO_NUM     18
#define Y6_GPIO_NUM     12
#define Y5_GPIO_NUM     10
#define Y4_GPIO_NUM      8
#define Y3_GPIO_NUM      9
#define Y2_GPIO_NUM     11
#define VSYNC_GPIO_NUM   6
#define HREF_GPIO_NUM    7
#define PCLK_GPIO_NUM   13

// ============================================================
//  ライン検出パラメータ
// ============================================================
const int IMG_W = 160;           // QQVGA 幅
const int IMG_H = 120;           // QQVGA 高さ
const int ROI_Y_TOP    = 90;     // ROI の開始行（下から30行）
const int ROI_Y_BOTTOM = 119;    // ROI の終了行（最終行）
const int BIN_THRESHOLD  = 80;   // 0..255、これ以下を黒ライン扱い（白背景・黒テープ前提）
const int MIN_BLACK_PIXELS = 30; // これ未満ならライン未検出（NA）

// ============================================================
//  送信レート制御
// ============================================================
const uint32_t SEND_INTERVAL_MS = 33; // ≒30Hz

// ============================================================
//  デバッグ出力間隔
// ============================================================
const uint32_t DEBUG_INTERVAL_MS = 1000; // 1秒に1回

// ============================================================
//  関数プロトタイプ
// ============================================================
bool initCamera();
int  detectLineError(camera_fb_t* fb, bool& ok);
void sendError(int err, bool ok);

// ============================================================
void setup()
{
  // USB デバッグ用シリアル
  Serial.begin(115200);

  // UNO R4 WiFi への送信用 UART
  // RX=44(未使用), TX=43 → UNO R4 D0(Serial1 RX) へ接続
  Serial1.begin(115200, SERIAL_8N1, 44, 43);

  if (!initCamera()) {
    // カメラ初期化失敗 → 暴走させず停止
    while (1) delay(1000);
  }

  Serial.println("Camera init OK");
  Serial.println("Starting line detection...");
}

// ============================================================
void loop()
{
  static uint32_t lastSend  = 0;
  static uint32_t lastDebug = 0;
  static uint32_t frameCount = 0;
  static int lastErr = 0;
  static int lastBlack = 0;
  static int lastCenterX = 0;

  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) {
    Serial.println("Camera capture failed");
    delay(100);
    return;
  }

  // 送信レート制御（最大30Hz）
  if (millis() - lastSend < SEND_INTERVAL_MS) {
    esp_camera_fb_return(fb);
    return;
  }
  lastSend = millis();
  frameCount++;

  bool ok = false;
  int err = detectLineError(fb, ok);
  esp_camera_fb_return(fb);

  sendError(err, ok);

  // デバッグ用に直近の値を保存（detectLineError から取り出す方法として再計算は重いので
  // 呼び出し側で保持する設計にはせず、1秒ごとの統計として frameCount で FPS 計算のみ行う）
  if (ok) {
    lastErr = err;
  }

  // 1秒ごとにデバッグ出力
  if (millis() - lastDebug >= DEBUG_INTERVAL_MS) {
    float fps = (float)frameCount / ((millis() - lastDebug + DEBUG_INTERVAL_MS) / 1000.0f);
    Serial.printf("[%.1f fps] err=%d valid=%s\n",
                  fps,
                  ok ? lastErr : 0,
                  ok ? "YES" : "NA");
    frameCount  = 0;
    lastDebug   = millis();
  }
}

// ============================================================
//  カメラ初期化
//  戻り値: true=成功, false=失敗（呼び出し元で停止すること）
// ============================================================
bool initCamera()
{
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0       = Y2_GPIO_NUM;
  config.pin_d1       = Y3_GPIO_NUM;
  config.pin_d2       = Y4_GPIO_NUM;
  config.pin_d3       = Y5_GPIO_NUM;
  config.pin_d4       = Y6_GPIO_NUM;
  config.pin_d5       = Y7_GPIO_NUM;
  config.pin_d6       = Y8_GPIO_NUM;
  config.pin_d7       = Y9_GPIO_NUM;
  config.pin_xclk     = XCLK_GPIO_NUM;
  config.pin_pclk     = PCLK_GPIO_NUM;
  config.pin_vsync    = VSYNC_GPIO_NUM;
  config.pin_href     = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn     = PWDN_GPIO_NUM;
  config.pin_reset    = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;              // 20MHz
  config.pixel_format = PIXFORMAT_GRAYSCALE;   // 二値化のためグレースケール
  config.frame_size   = FRAMESIZE_QQVGA;       // 160x120（処理軽量）
  config.jpeg_quality = 12;                    // GRAYSCALE 時は無視されるがセット
  config.fb_count     = 1;
  config.fb_location  = CAMERA_FB_IN_PSRAM;    // PSRAM 必須
  config.grab_mode    = CAMERA_GRAB_LATEST;    // 最新フレーム優先

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init failed: 0x%x\n", err);
    return false;
  }
  return true;
}

// ============================================================
//  ライン誤差検出（重心法）
//
//  引数:
//    fb  : esp_camera_fb_get() で取得したフレームバッファ
//    ok  : true=ライン検出成功、false=未検出（NA）
//  戻り値:
//    ライン誤差 -100(左端) 〜 +100(右端)。ok=false の場合は 0 を返す
// ============================================================
int detectLineError(camera_fb_t* fb, bool& ok)
{
  ok = false;

  if (!fb || !fb->buf) return 0;

  long sumX  = 0;
  int  count = 0;

  // ROI（下部30行）を走査
  for (int y = ROI_Y_TOP; y <= ROI_Y_BOTTOM; y++) {
    for (int x = 0; x < IMG_W; x++) {
      uint8_t pixel = fb->buf[y * IMG_W + x];
      if (pixel <= BIN_THRESHOLD) {   // 黒ライン判定（白背景前提）
        sumX += x;
        count++;
      }
    }
  }

  if (count < MIN_BLACK_PIXELS) {
    // ライン未検出
    return 0;
  }

  int centerX = (int)(sumX / count);
  int err = map(centerX, 0, IMG_W - 1, -100, 100);

  ok = true;
  return err;
}

// ============================================================
//  誤差を Serial1 で UNO R4 へ送信
//
//  ok=true  → "L:<err>\n"
//  ok=false → "L:NA\n"
// ============================================================
void sendError(int err, bool ok)
{
  if (ok) {
    Serial1.printf("L:%d\n", err);
  } else {
    Serial1.println("L:NA");
  }
}
