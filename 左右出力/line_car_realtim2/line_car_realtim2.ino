/*
 * ============================================================
 *  2サーボ ラインカー  ―  左右独立で速度制御 (リアルタイム)
 *  Arduino UNO R4 WiFi
 * ============================================================
 *  Mac(Processing 左右2スライダー) --UDP--> UNO R4 --> L/R サーボ
 *
 *    L_SERVO = 1500 + L_SPEED
 *    R_SERVO = 1500 - R_SPEED      (R は鏡対称なので符号反転)
 *    SPEED は -500〜500 (0=停止)
 *
 *  プロトコル:
 *    "LR:<left>,<right>"   左右の速度(各 -100〜100)。例 "LR:80,60"
 *    "RUN:1" / "RUN:0"     走行開始 / 停止
 *    "STOP"                即停止
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
int  leftPct  = 0;   // -100〜100
int  rightPct = 0;   // -100〜100
bool running  = false;

// 通信が途絶えたら安全停止
unsigned long lastCmdMs = 0;
const unsigned long CMD_TIMEOUT = 2000; // ms

void setup()
{
  Serial.begin(115200);

  L_SERVO.attach(14, 1000, 2000); // PORT(A0)
  R_SERVO.attach(15, 1000, 2000); // PORT(A1)

  L_SERVO.writeMicroseconds(1500);
  R_SERVO.writeMicroseconds(1500);

  connectWiFi();
  Udp.begin(LOCAL_UDP_PORT);
  Serial.print("UDP listening on port ");
  Serial.println(LOCAL_UDP_PORT);
}

void loop()
{
  receiveUDP();

  if (millis() - lastCmdMs > CMD_TIMEOUT) {
    running = false;
  }

  // 左右それぞれ %→オフセット(us)へ変換
  if (running) {
    L_SPEED = map(leftPct,  -100, 100, -MAX_OFFSET, MAX_OFFSET);
    R_SPEED = map(rightPct, -100, 100, -MAX_OFFSET, MAX_OFFSET);
  } else {
    L_SPEED = 0;
    R_SPEED = 0;
  }

  // 毎ループ出力 → リアルタイム反映
  L_SERVO.writeMicroseconds(1500 + L_SPEED);
  R_SERVO.writeMicroseconds(1500 - R_SPEED);
}

// ============================================================
void connectWiFi()
{
  // ★Galaxy A51 テザリングの範囲に合わせた固定IP（環境に合わせて変更）
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

  if (msg.startsWith("LR:")) {
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

  Serial.print("recv \"");
  Serial.print(msg);
  Serial.print("\"  L=");
  Serial.print(leftPct);
  Serial.print("  R=");
  Serial.print(rightPct);
  Serial.print("  run=");
  Serial.println(running ? "ON" : "OFF");

  // ACK 返信
  Udp.beginPacket(Udp.remoteIP(), Udp.remotePort());
  Udp.print("ACK L=");
  Udp.print(leftPct);
  Udp.print(" R=");
  Udp.print(rightPct);
  Udp.print(" run=");
  Udp.print(running ? 1 : 0);
  Udp.endPacket();
}
