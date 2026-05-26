/*
 * ============================================================
 *  速度調整可能ラインカー  ―  Arduino UNO R4 WiFi 用スケッチ
 * ============================================================
 *
 *  構成:
 *    - Mac (Processing スライダー) --UDP--> UNO R4 WiFi : 速度設定
 *    - ESP32-S3 (カメラ) --Serial1--> UNO R4 WiFi       : ライン位置(誤差)
 *    - UNO R4 WiFi --PWM(サーボ信号)--> FS90R-W x4       : 走行
 *
 *  ★ FS90R-W は「連続回転サーボ」です。
 *    信号線に入るパルス幅で速度・方向が決まります。
 *      1500us = 停止 / >1500 = 一方向 / <1500 = 逆方向
 *    Servo ライブラリの writeMicroseconds() で制御します。
 *    (TB6612 は DC モーター用なのでサーボには使いません)
 *
 *  ★ もし将来 DC モーター + TB6612 に変更する場合は、
 *    writeSide() の中身を analogWrite()+方向ピン制御に
 *    差し替えてください(下部のコメント参照)。
 * ============================================================
 */

#include <WiFiS3.h>     // UNO R4 WiFi 内蔵 WiFi
#include <WiFiUdp.h>
#include <Servo.h>

// ---------- WiFi 設定（自分の環境に合わせて書き換え）----------
const char* WIFI_SSID = "あなたのSSID";
const char* WIFI_PASS = "あなたのパスワード";
const unsigned int LOCAL_UDP_PORT = 8888;   // Processing から送る宛先ポート

WiFiUDP Udp;
char packetBuf[64];

// ---------- サーボ（FS90R-W x4）----------
// 左前, 左後, 右前, 右後
Servo servoLF, servoLR, servoRF, servoRR;
const int PIN_LF = 3;
const int PIN_LR = 5;
const int PIN_RF = 6;
const int PIN_RR = 9;

// 停止パルス幅。FS90R-W 本体のトリマで微調整できるが、
// 個体差で停止せずクリープする場合はここを 1490〜1510 で調整。
const int STOP_US = 1500;
// 停止からの最大オフセット(us)。1500±MAX_OFFSET の範囲で動かす。
const int MAX_OFFSET = 400;       // → 1100〜1900us

// 左右の取り付け向きが鏡対称なので、片側は符号を反転させる。
// 前進させたとき車輪が逆に回る側は、その符号を -1 に変えること。
const int DIR_LEFT  = +1;
const int DIR_RIGHT = -1;

// ---------- 走行パラメータ ----------
int   baseSpeed   = 0;     // 0〜100 (%) … Processing スライダーで設定
bool  running     = false; // RUN フラグ
int   lineError   = 0;     // ESP32-S3 から受信するライン誤差 (-100〜+100)
float Kp          = 0.6;   // ステアリング比例ゲイン（要調整）

// 通信タイムアウト（一定時間 UDP/Serial が来なければ安全停止）
unsigned long lastCmdMs  = 0;
const unsigned long CMD_TIMEOUT = 2000; // ms

// ---------- Serial1 (ESP32-S3) 受信バッファ ----------
String s1buf = "";

// ============================================================
void setup() {
  Serial.begin(115200);      // デバッグ用 (USB)
  Serial1.begin(115200);     // ESP32-S3 との通信 (D0=RX, D1=TX)

  servoLF.attach(PIN_LF);
  servoLR.attach(PIN_LR);
  servoRF.attach(PIN_RF);
  servoRR.attach(PIN_RR);
  stopAll();                 // 起動直後は必ず停止

  connectWiFi();
  Udp.begin(LOCAL_UDP_PORT);
  Serial.print("UDP listening on port ");
  Serial.println(LOCAL_UDP_PORT);
}

// ============================================================
void loop() {
  receiveUDP();      // Mac からの速度/RUN コマンド
  receiveSerial();   // ESP32-S3 からのライン誤差

  // セーフティ: 一定時間コマンドが来なければ停止
  if (millis() - lastCmdMs > CMD_TIMEOUT) {
    running = false;
  }

  if (running) {
    drive();
  } else {
    stopAll();
  }
}

// ============================================================
//  WiFi 接続
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
  Serial.print("Connected. IP = ");
  Serial.println(WiFi.localIP());   // ★この IP を Processing 側に設定する
}

// ============================================================
//  UDP 受信  ―  プロトコル: テキスト
//    "SPD:75"   → baseSpeed = 75 (0〜100)
//    "RUN:1"    → 走行開始 / "RUN:0" → 停止
//    "STOP"     → 即停止
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
    lastCmdMs = millis();
  } else if (msg.startsWith("RUN:")) {
    running = (msg.substring(4).toInt() != 0);
    lastCmdMs = millis();
  } else if (msg == "STOP") {
    running = false;
    lastCmdMs = millis();
  }

  Serial.print("UDP recv: ");
  Serial.print(msg);
  Serial.print("  -> speed=");
  Serial.print(baseSpeed);
  Serial.print(" run=");
  Serial.println(running);

  // （任意）受信確認を送信元へ返す
  Udp.beginPacket(Udp.remoteIP(), Udp.remotePort());
  Udp.print("ACK speed=");
  Udp.print(baseSpeed);
  Udp.print(" run=");
  Udp.print(running ? 1 : 0);
  Udp.endPacket();
}

// ============================================================
//  Serial1 受信 (ESP32-S3 から)
//    プロトコル: "L:<誤差>\n"   誤差 = -100(左) 〜 +100(右)
// ============================================================
void receiveSerial() {
  while (Serial1.available()) {
    char c = Serial1.read();
    if (c == '\n') {
      s1buf.trim();
      if (s1buf.startsWith("L:")) {
        lineError = constrain(s1buf.substring(2).toInt(), -100, 100);
      }
      s1buf = "";
    } else {
      s1buf += c;
      if (s1buf.length() > 32) s1buf = "";  // 異常データ防止
    }
  }
}

// ============================================================
//  走行制御
//    ベース速度に、ライン誤差からのステアリング補正を加える
// ============================================================
void drive() {
  float correction = Kp * lineError;          // 右に寄ったら右を遅く
  int leftSpeed  = baseSpeed - (int)correction;
  int rightSpeed = baseSpeed + (int)correction;

  leftSpeed  = constrain(leftSpeed,  -100, 100);
  rightSpeed = constrain(rightSpeed, -100, 100);

  writeSide(servoLF, servoLR, leftSpeed,  DIR_LEFT);
  writeSide(servoRF, servoRR, rightSpeed, DIR_RIGHT);
}

// 片側 2 サーボへ同じ速度を出力 (speed: -100〜100)
void writeSide(Servo &a, Servo &b, int speed, int dir) {
  int us = STOP_US + dir * map(speed, -100, 100, -MAX_OFFSET, MAX_OFFSET);
  us = constrain(us, STOP_US - MAX_OFFSET, STOP_US + MAX_OFFSET);
  a.writeMicroseconds(us);
  b.writeMicroseconds(us);

  /* ---- DC モーター + TB6612 に変更する場合の置き換え例 ----
     （PWM ピンと方向ピンを別途定義しておくこと）
     int pwm = map(abs(speed), 0, 100, 0, 255);
     bool fwd = (dir * speed) >= 0;
     digitalWrite(AIN1, fwd ? HIGH : LOW);
     digitalWrite(AIN2, fwd ? LOW  : HIGH);
     analogWrite(PWMA, pwm);
  --------------------------------------------------------- */
}

void stopAll() {
  servoLF.writeMicroseconds(STOP_US);
  servoLR.writeMicroseconds(STOP_US);
  servoRF.writeMicroseconds(STOP_US);
  servoRR.writeMicroseconds(STOP_US);
}
