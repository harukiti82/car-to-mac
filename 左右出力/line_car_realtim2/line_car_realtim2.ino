/*
 * ============================================================
 *  2サーボ ラインカー  ―  左右独立で速度制御 (リアルタイム)
 *  Arduino UNO R4 WiFi  ― APモード（Arduino がホスト）
 * ============================================================
 *  UNO R4 が WiFi アクセスポイントを立て、Mac が接続する
 *  Mac(Processing) --UDP--> UNO R4 (192.168.4.1) --> L/R サーボ
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

#include <WiFiS3.h>
#include <WiFiUdp.h>
#include "FspTimer.h"

// ---------- WiFi AP 設定 ----------
const char* AP_SSID = "LineCar";
const char* AP_PASS = "linecar1234";   // 8文字以上必須
const unsigned int LOCAL_UDP_PORT = 8888;

WiFiUDP Udp;
char packetBuf[64];

// ---------- サーボ（FspTimer によるハードウェアパルス生成）----------
const int L_PIN = 9;
const int R_PIN = 10;

int L_SPEED = 0;   // -500〜500 (0=STOP)
int R_SPEED = 0;   // -500〜500 (0=STOP)

const int MAX_OFFSET = 500;   // 100% のときのオフセット(us)

// ---------- サーボパルス生成用タイマー ----------
//  50us ティックの周期割り込みで 50Hz(20ms) のサーボパルスを作る。
//  loop() の負荷（WiFi/UART処理）と無関係に安定したパルスを出し続ける。
FspTimer servoTimer;

#define SERVO_TICK_US     50                              // 割り込み周期(us)
#define SERVO_FRAME_US    20000                           // サーボフレーム(us)=50Hz
#define SERVO_FRAME_TICKS (SERVO_FRAME_US / SERVO_TICK_US) // = 400

// loop() が書き、ISR がフレーム先頭でラッチする目標パルス幅(us)
volatile uint16_t g_pulseL_us = 1500;  // 1500=停止
volatile uint16_t g_pulseR_us = 1500;

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
//  サーボパルス生成 ISR（50us ごとに呼ばれる）
//    フレーム先頭(tick==0)で両ピンHIGH＆幅をラッチし、
//    各ピンの幅に達した tick で LOW に落とす。
// ============================================================
void servoISR(timer_callback_args_t * /*args*/)
{
  static uint16_t tick    = 0;
  static uint16_t Lticks  = 1500 / SERVO_TICK_US;
  static uint16_t Rticks  = 1500 / SERVO_TICK_US;

  if (tick == 0) {
    // フレーム先頭：目標幅をラッチして両ピンを立てる
    Lticks = g_pulseL_us / SERVO_TICK_US;
    Rticks = g_pulseR_us / SERVO_TICK_US;
    digitalWrite(L_PIN, HIGH);
    digitalWrite(R_PIN, HIGH);
  } else {
    if (tick == Lticks) digitalWrite(L_PIN, LOW);
    if (tick == Rticks) digitalWrite(R_PIN, LOW);
  }

  if (++tick >= SERVO_FRAME_TICKS) tick = 0;
}

// ============================================================
//  サーボタイマー初期化（50us=20kHz の周期割り込み）
// ============================================================
void setupServoTimer()
{
  uint8_t type;
  int8_t  ch = FspTimer::get_available_timer(type);
  if (ch < 0) {
    // 通常タイマーが空いていなければ PWM 予約タイマーを使う
    FspTimer::force_use_of_pwm_reserved_timer();
    ch = FspTimer::get_available_timer(type, true);
  }
  if (ch < 0) {
    Serial.println("Servo timer: no available timer!");
    return;
  }

  // 20000Hz = 50us 周期、デューティは使わない(0)
  servoTimer.begin(TIMER_MODE_PERIODIC, type, ch, 20000.0f, 0.0f, servoISR);
  servoTimer.setup_overflow_irq();
  servoTimer.open();
  servoTimer.start();
  Serial.print("Servo timer started (type=");
  Serial.print(type);
  Serial.print(" ch=");
  Serial.print(ch);
  Serial.println(")");
}

// ============================================================
void setup()
{
  Serial.begin(115200);
  Serial.println("=== line_car v4 fsp-timer ===");

  pinMode(L_PIN, OUTPUT);
  pinMode(R_PIN, OUTPUT);
  digitalWrite(L_PIN, LOW);
  digitalWrite(R_PIN, LOW);

  setupServoTimer();      // サーボパルスをハードウェアタイマーで生成開始

  Serial1.begin(115200);  // ESP32-S3 CAM 受信用

  startAP();
  Udp.begin(LOCAL_UDP_PORT);
  Serial.print("UDP listening on port ");
  Serial.println(LOCAL_UDP_PORT);
}

// ============================================================
void loop()
{

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

  // 目標パルス幅を更新するだけ（実際のパルスは servoISR が独立生成）
  g_pulseL_us = constrain(1500 + L_SPEED, 1000, 2000);
  g_pulseR_us = constrain(1500 - R_SPEED, 1000, 2000);

  // デバッグ: パルス幅の値を確認
  static unsigned long lastDbg = 0;
  if (Serial && millis() - lastDbg > 500) {
    lastDbg = millis();
    Serial.print("PULSE L=");
    Serial.print(g_pulseL_us);
    Serial.print(" R=");
    Serial.println(g_pulseR_us);
  }

  delay(5);  // loop を回しすぎない程度（パルス生成はISR側なので影響しない）
}

// ============================================================
void startAP()
{
  Serial.print("Starting AP: ");
  Serial.println(AP_SSID);

  int status = WiFi.beginAP(AP_SSID, AP_PASS);
  if (status != WL_AP_LISTENING) {
    Serial.println("AP failed! Retrying...");
    delay(1000);
    status = WiFi.beginAP(AP_SSID, AP_PASS);
  }

  Serial.print("AP started!  IP = ");
  Serial.println(WiFi.localIP());   // 192.168.4.1
}

// ============================================================
//  UDP 受信
//    MODE:AUTO / MODE:MANUAL / SPD:<n> / LR:<l>,<r> / RUN:<n> / STOP
// ============================================================
void receiveUDP()
{
  int packetSize;
  // 1フレームで複数パケット届いた場合も全部処理する
  while ((packetSize = Udp.parsePacket()) > 0) {
    int len = Udp.read(packetBuf, sizeof(packetBuf) - 1);
    if (len <= 0) continue;
    packetBuf[len] = '\0';

    String msg = String(packetBuf);
    msg.trim();

    // ACK 返信先を確定しておく（endPacket 前に remoteIP が変わる場合に備え）
    IPAddress remoteIp   = Udp.remoteIP();
    uint16_t  remotePort = Udp.remotePort();

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
        running   = true;   // LR: 受信で自動走行開始（Processing側と連動）
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
    Udp.beginPacket(remoteIp, remotePort);
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
}

// ============================================================
//  Serial1 受信 (ESP32-S3 CAM から)
//    プロトコル: "L:<誤差>\n"   誤差 = -100(左) 〜 +100(右)
//               "L:NA\n"       ライン未検出
// ============================================================
void receiveSerial1()
{
  // 1回の loop で処理するバイト数を制限し、CAM の連投で UDP 応答が
  // 詰まる（loop が長時間ブロックされる）のを防ぐ
  int guard = 0;
  while (Serial1.available() && guard++ < 64) {
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
