/*
 * ============================================================
 *  UDP 通信テスト用スケッチ  ―  Arduino UNO R4 WiFi
 * ============================================================
 *  モータードライバ・サーボがまだ無くても、
 *  Mac(Processing スライダー) → UDP → UNO R4 の通信だけを
 *  確認するためのテストコードです。
 *
 *  受信した速度を…
 *    (1) シリアルモニタに表示
 *    (2) 内蔵 LED マトリクス(12x8)に横バーで表示  ← 追加部品不要
 *    (3) 内蔵 LED で RUN 状態を表示 (走行ON=点灯)
 *
 *  Processing 側 (line_car_controller.pde) はそのまま使えます。
 *  プロトコル: "SPD:0-100" / "RUN:1" / "RUN:0" / "STOP"
 * ============================================================
 */

#include <WiFiS3.h>
#include <WiFiUdp.h>
#include "Arduino_LED_Matrix.h"   // UNO R4 ボードパッケージに同梱

// ---------- WiFi 設定（自分の環境に書き換え）----------
const char* WIFI_SSID = "あなたのSSID";
const char* WIFI_PASS = "あなたのパスワード";
const unsigned int LOCAL_UDP_PORT = 8888;

WiFiUDP Udp;
char packetBuf[64];

ArduinoLEDMatrix matrix;

// ---------- 受信した状態 ----------
int  baseSpeed = 0;      // 0〜100
bool running   = false;

void setup() {
  Serial.begin(115200);
  while (!Serial && millis() < 3000) { /* USB シリアル待ち(最大3秒) */ }

  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);

  matrix.begin();

  connectWiFi();
  Udp.begin(LOCAL_UDP_PORT);
  Serial.print("UDP listening on port ");
  Serial.println(LOCAL_UDP_PORT);
  Serial.println("Processing から SPD: / RUN: を送ってください。");

  drawBar(0);
}

void loop() {
  receiveUDP();

  // RUN 状態を内蔵 LED に反映
  digitalWrite(LED_BUILTIN, running ? HIGH : LOW);
}

// ============================================================
void connectWiFi() {
  Serial.print("Connecting to ");
  Serial.println(WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();
  Serial.print("Connected!  IP = ");
  Serial.println(WiFi.localIP());   // ★この IP を Processing の ARDUINO_IP に設定
}

// ============================================================
//  UDP 受信
// ============================================================
void receiveUDP() {
  int packetSize = Udp.parsePacket();
  if (packetSize <= 0) return;

  int len = Udp.read(packetBuf, sizeof(packetBuf) - 1);
  if (len <= 0) return;
  packetBuf[len] = '\0';

  String msg = String(packetBuf);
  msg.trim();

  if (msg.startsWith("SPD:")) {
    baseSpeed = constrain(msg.substring(4).toInt(), 0, 100);
    drawBar(baseSpeed);
  } else if (msg.startsWith("RUN:")) {
    running = (msg.substring(4).toInt() != 0);
  } else if (msg == "STOP") {
    running = false;
  }

  // シリアルモニタに表示
  Serial.print("recv from ");
  Serial.print(Udp.remoteIP());
  Serial.print(":");
  Serial.print(Udp.remotePort());
  Serial.print("  msg=\"");
  Serial.print(msg);
  Serial.print("\"  -> speed=");
  Serial.print(baseSpeed);
  Serial.print("%  run=");
  Serial.println(running ? "ON" : "OFF");

  // ACK を返す（Processing 側で受信確認できる）
  Udp.beginPacket(Udp.remoteIP(), Udp.remotePort());
  Udp.print("ACK speed=");
  Udp.print(baseSpeed);
  Udp.print(" run=");
  Udp.print(running ? 1 : 0);
  Udp.endPacket();
}

// ============================================================
//  LED マトリクス(12列x8行)に速度を横バー表示
//  speed 0〜100 → 0〜12 列を点灯
// ============================================================
void drawBar(int speed) {
  uint8_t frame[8][12] = {{0}};
  int cols = map(speed, 0, 100, 0, 12);
  for (int r = 0; r < 8; r++) {
    for (int c = 0; c < cols; c++) {
      frame[r][c] = 1;
    }
  }
  matrix.renderBitmap(frame, 8, 12);
}
