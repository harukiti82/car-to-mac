/*
 * ============================================================
 *  2サーボ ラインカー  ―  Processing スライダーをリアルタイム反映
 *  Arduino UNO R4 WiFi
 * ============================================================
 *  Mac(Processing) --UDP--> UNO R4 --> L/R サーボ(FS90R-W)
 *
 *  元コードの考え方そのまま:
 *    L_SERVO = 1500 + L_SPEED
 *    R_SERVO = 1500 - R_SPEED      (R は鏡対称なので符号反転)
 *    SPEED は -500〜500 (0=停止)
 *
 *  Processing から届く速度(0〜100%)を 0〜500us に変換して反映。
 *  while(1) は使わず loop() で毎回更新するのでリアルタイムに変わる。
 *
 *  プロトコル: "SPD:0-100" / "RUN:1" / "RUN:0" / "STOP"
 *  ※ Processing 側 line_car_controller.pde はそのまま使えます。
 * ============================================================
 */

#include <Servo.h>
#include <WiFiS3.h>
#include <WiFiUdp.h>

// ---------- WiFi 設定（自分の環境に書き換え）----------
const char* WIFI_SSID = "Galaxy A2047DC";
const char* WIFI_PASS = "rpmn9776";
const unsigned int LOCAL_UDP_PORT = 8888;

WiFiUDP Udp;
char packetBuf[64];

// ---------- サーボ ----------
Servo L_SERVO;
Servo R_SERVO;

int R_SPEED = 0;   // -500〜500 (0=STOP)
int L_SPEED = 0;   // -500〜500 (0=STOP)

const int MAX_OFFSET = 500;   // 100% のときのオフセット(us)

// ---------- Processing から受け取る状態 ----------
int  baseSpeed = 0;       // 0〜100 (%)
bool running   = false;

// 通信が途絶えたら安全停止
unsigned long lastCmdMs = 0;
const unsigned long CMD_TIMEOUT = 2000; // ms

void setup()
{
  Serial.begin(115200);

  L_SERVO.attach(14, 1000, 2000); // PORT(A0), MIN, MAX
  R_SERVO.attach(15, 1000, 2000); // PORT(A1), MIN, MAX

  // 起動直後は停止
  L_SERVO.writeMicroseconds(1500);
  R_SERVO.writeMicroseconds(1500);

  connectWiFi();
  Udp.begin(LOCAL_UDP_PORT);
  Serial.print("UDP listening on port ");
  Serial.println(LOCAL_UDP_PORT);
}

void loop()
{
  receiveUDP();   // スライダー値を受信して baseSpeed / running を更新

  // 一定時間コマンドが来なければ安全停止
  if (millis() - lastCmdMs > CMD_TIMEOUT) {
    running = false;
  }

  // 速度(%)→ オフセット(us)へ変換
  if (running) {
    int offset = map(baseSpeed, 0, 100, 0, MAX_OFFSET);
    L_SPEED = offset;
    R_SPEED = offset;
  } else {
    L_SPEED = 0;
    R_SPEED = 0;
  }

  // 毎ループ出力 → リアルタイムに反映
  L_SERVO.writeMicroseconds(1500 + L_SPEED);
  R_SERVO.writeMicroseconds(1500 - R_SPEED);
}

// ============================================================
void connectWiFi()
{
  // ★Galaxy A51 テザリングの範囲に合わせる
  IPAddress ip(10, 123, 106, 50);       // 本機のIP（空き番号）
  IPAddress dns(10, 123, 106, 9);       // ゲートウェイと同じ
  IPAddress gateway(10, 123, 106, 9);
  IPAddress subnet(255, 255, 255, 0);
  WiFi.config(ip, dns, gateway, subnet);

  Serial.print("Connecting to ");
  Serial.println(WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print("."); }

  Serial.println();
  Serial.print("Connected!  IP = ");
  Serial.println(WiFi.localIP());       // 10.123.106.50 と出ればOK
}

// ============================================================
//  UDP 受信
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

  Serial.print("recv \"");
  Serial.print(msg);
  Serial.print("\"  speed=");
  Serial.print(baseSpeed);
  Serial.print("%  run=");
  Serial.println(running ? "ON" : "OFF");

  // ACK 返信
  Udp.beginPacket(Udp.remoteIP(), Udp.remotePort());
  Udp.print("ACK speed=");
  Udp.print(baseSpeed);
  Udp.print(" run=");
  Udp.print(running ? 1 : 0);
  Udp.endPacket();
}
