/*
 * ============================================================
 *  2サーボ ラインカー  ―  左右独立で速度制御 (リアルタイム)
 *  Arduino UNO R4 WiFi
 * ============================================================
 *  Mac(Processing) --UDP--> UNO R4 --> L/R サーボ
 *  ESP32-S3 CAM   --Serial1(UART)--> UNO R4  (ライン誤差)
 *
 *    L_SERVO = 1500 + L_SPEED
 *    R_SERVO = 1500 - R_SPEED      (R は鏡対称なので符号反転)
 *    SPEED は -500〜500 (0=停止)
 *
 *  UDP プロトコル:
 *    "MODE:AUTO"            ライントレースモード
 *    "MODE:MANUAL"          手動モード（デフォルト）
 *    "SPD:<0..100>"         AUTO 時のベース速度
 *    "LR:<left>,<right>"    MANUAL 時の左右速度 (-100〜100)
 *    "RUN:1" / "RUN:0"      走行開始 / 停止
 *    "STOP"                 即停止
 *
 *  Serial1 プロトコル (ESP32-S3 CAM から):
 *    "L:<-100..100>\n"      ライン誤差（負=左、正=右、0=中央）
 *    "L:NA\n"               ライン未検出
 * ============================================================
 */

#include <Servo.h>
#include <WiFiS3.h>
#include <WiFiUdp.h>

// ---------- WiFi 設定 ----------
const char* WIFI_SSID = "Galaxy A2047DC";
const char* WIFI_PASS = "rpmn9776";
const unsigned int LOCAL_UDP_PORT = 8888;

WiFiUDP Udp;
char packetBuf[64];

// ---------- サーボ ----------
Servo L_SERVO;
Servo R_SERVO;

int L_SPEED = 0;   // -500〜500 (0=STOP)
int R_SPEED = 0;   // -500〜500 (0=STOP)

const int MAX_OFFSET = 500;   // 100% のときのオフセット(us)

// ---------- Processing から受け取る状態 ----------
int  leftPct  = 0;   // -100〜100 (MANUAL モード用)
int  rightPct = 0;   // -100〜100 (MANUAL モード用)
bool running  = false;

// 通信が途絶えたら安全停止
unsigned long lastCmdMs = 0;
const unsigned long CMD_TIMEOUT = 2000; // ms

// ---------- モード ----------
enum DriveMode { MODE_MANUAL, MODE_AUTO };
DriveMode mode = MODE_MANUAL;

// ---------- AUTO モード用 ----------
int   baseSpeed = 0;      // 0..100 (%)。AUTO 時のベース速度
int   lineError = 0;      // -100..100、ESP32 から受信
bool  lineValid = false;  // 直近の L: が NA でないか
float Kp = 0.6f;          // 比例ゲイン（実機で 0.4〜1.0 を試す）
float Kd = 0.2f;          // 微分ゲイン（揺れが大きいなら下げる）
int   prevError = 0;

// ---------- ライン消失タイムアウト ----------
unsigned long lastLineMs = 0;
const unsigned long LINE_TIMEOUT = 500; // ms

// ---------- Serial1 受信バッファ ----------
String s1buf = "";

// ============================================================
void setup()
{
  Serial.begin(115200);

  L_SERVO.attach(14, 1000, 2000); // PORT(A0)
  R_SERVO.attach(15, 1000, 2000); // PORT(A1)

  L_SERVO.writeMicroseconds(1500);
  R_SERVO.writeMicroseconds(1500);

  Serial1.begin(115200);  // ESP32-S3 CAM 受信用

  connectWiFi();
  Udp.begin(LOCAL_UDP_PORT);
  Serial.print("UDP listening on port ");
  Serial.println(LOCAL_UDP_PORT);
}

// ============================================================
void loop()
{
  // WiFi が切断されていたら再接続
  if (WiFi.status() != WL_CONNECTED) {
    if (Serial) Serial.println("WiFi disconnected. Reconnecting...");
    connectWiFi();
    Udp.begin(LOCAL_UDP_PORT);
  }

  receiveUDP();
  receiveSerial1();

  // UDP 通信タイムアウトで安全停止
  if (millis() - lastCmdMs > CMD_TIMEOUT) {
    running = false;
  }

  if (!running) {
    L_SPEED = 0;
    R_SPEED = 0;
  } else if (mode == MODE_AUTO) {
    // AUTO: ベース速度 + PD 補正
    if (!lineValid || millis() - lastLineMs > LINE_TIMEOUT) {
      // ライン消失 → 停止（安全側）
      L_SPEED = 0;
      R_SPEED = 0;
    } else {
      int err  = lineError;
      int dErr = err - prevError;
      float steer = Kp * err + Kd * dErr;  // err>0(右寄り) → 右を遅く
      int leftPctAuto  = constrain(baseSpeed + (int)steer, -100, 100);
      int rightPctAuto = constrain(baseSpeed - (int)steer, -100, 100);
      L_SPEED = map(leftPctAuto,  -100, 100, -MAX_OFFSET, MAX_OFFSET);
      R_SPEED = map(rightPctAuto, -100, 100, -MAX_OFFSET, MAX_OFFSET);
      prevError = err;
    }
  } else {
    // MANUAL: 既存ロジックそのまま
    L_SPEED = map(leftPct,  -100, 100, -MAX_OFFSET, MAX_OFFSET);
    R_SPEED = map(rightPct, -100, 100, -MAX_OFFSET, MAX_OFFSET);
  }

  // 毎ループ出力 → リアルタイム反映
  L_SERVO.writeMicroseconds(1500 + L_SPEED);
  R_SERVO.writeMicroseconds(1500 - R_SPEED);   // R は鏡対称で符号反転

  // WiFi スタックとサーボタイマー割り込みの競合を緩和
  delay(10);
}

// ============================================================
void connectWiFi()
{
  // 固定IP（環境に合わせて変更）
  IPAddress ip(10, 123, 106, 50);
  IPAddress dns(10, 123, 106, 9);
  IPAddress gateway(10, 123, 106, 9);
  IPAddress subnet(255, 255, 255, 0);
  WiFi.config(ip, dns, gateway, subnet);

  Serial.print("Connecting to ");
  Serial.println(WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print("."); }

  Serial.println();
  Serial.print("Connected!  IP = ");
  Serial.println(WiFi.localIP());
}

// ============================================================
//  UDP 受信
//    MODE:AUTO / MODE:MANUAL / SPD:<n> / LR:<l>,<r> / RUN:<n> / STOP
// ============================================================
void receiveUDP()
{
  int packetSize = Udp.parsePacket();
  if (packetSize <= 0) return;

  int len = Udp.read(packetBuf, sizeof(packetBuf) - 1);
  if (len <= 0) return;
  packetBuf[len] = '\0';

  String msg = String(packetBuf);
  msg.trim();

  if (msg == "MODE:AUTO") {
    mode = MODE_AUTO;
    lastCmdMs = millis();
  } else if (msg == "MODE:MANUAL") {
    mode = MODE_MANUAL;
    lastCmdMs = millis();
  } else if (msg.startsWith("SPD:")) {
    baseSpeed = constrain(msg.substring(4).toInt(), 0, 100);
    lastCmdMs = millis();
  } else if (msg.startsWith("LR:")) {
    // "LR:80,60" を分解
    String body = msg.substring(3);
    int comma = body.indexOf(',');
    if (comma > 0) {
      leftPct  = constrain(body.substring(0, comma).toInt(), -100, 100);
      rightPct = constrain(body.substring(comma + 1).toInt(), -100, 100);
      lastCmdMs = millis();
    }
  } else if (msg.startsWith("RUN:")) {
    running = (msg.substring(4).toInt() != 0);
    lastCmdMs = millis();
  } else if (msg == "STOP") {
    running = false;
    lastCmdMs = millis();
  }

  // USB 未接続（バッテリー駆動）のときバッファ満杯でブロックするのを防ぐ
  if (Serial) {
    Serial.print("recv \"");
    Serial.print(msg);
    Serial.print("\"  mode=");
    Serial.print(mode == MODE_AUTO ? "AUTO" : "MANUAL");
    Serial.print("  spd=");
    Serial.print(baseSpeed);
    Serial.print("  L=");
    Serial.print(leftPct);
    Serial.print("  R=");
    Serial.print(rightPct);
    Serial.print("  run=");
    Serial.println(running ? "ON" : "OFF");
  }

  // ACK 返信
  Udp.beginPacket(Udp.remoteIP(), Udp.remotePort());
  Udp.print("ACK mode=");
  Udp.print(mode == MODE_AUTO ? "AUTO" : "MANUAL");
  Udp.print(" spd=");
  Udp.print(baseSpeed);
  Udp.print(" L=");
  Udp.print(leftPct);
  Udp.print(" R=");
  Udp.print(rightPct);
  Udp.print(" run=");
  Udp.print(running ? 1 : 0);
  Udp.endPacket();
}

// ============================================================
//  Serial1 受信 (ESP32-S3 CAM から)
//    プロトコル: "L:<誤差>\n"   誤差 = -100(左) 〜 +100(右)
//               "L:NA\n"       ライン未検出
// ============================================================
void receiveSerial1()
{
  while (Serial1.available()) {
    char c = Serial1.read();
    if (c == '\n') {
      s1buf.trim();
      if (s1buf.startsWith("L:")) {
        String val = s1buf.substring(2);
        if (val == "NA") {
          lineValid = false;
        } else {
          lineError = constrain(val.toInt(), -100, 100);
          lineValid = true;
          lastLineMs = millis();
          if (Serial) {
            Serial.print("lineError=");
            Serial.println(lineError);
          }
        }
      }
      s1buf = "";
    } else {
      s1buf += c;
      if (s1buf.length() > 32) s1buf = "";  // 異常データ（バッファオーバーフロー防止）
    }
  }
}
