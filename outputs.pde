/*
 * ============================================================
 *  2モーター同時コントロール  ―  2D ジョイスティック版
 *  (Processing / 外部ライブラリ不要)
 * ============================================================
 *  パッドをドラッグして両モーターを同時に操作:
 *    上下  → 前進 / 後進 (両輪共通速度)
 *    左右  → ステアリング (左右差分)
 *
 *  内部計算:
 *    forward = -ny * 100   (上=+)
 *    steer   =  nx * 100   (右=+)
 *    leftVal  = forward + steer   (clamp -100〜100)
 *    rightVal = forward - steer   (clamp -100〜100)
 *
 *  送信プロトコル (Arduino と一致):
 *    "LR:<left>,<right>"   例 "LR:80,60"
 *    "RUN:1" / "RUN:0"     走行開始 / 停止
 *
 *  キー操作:
 *    Space … START / STOP 切り替え
 *    S     … 両輪0にリセット
 * ============================================================
 */

import java.net.*;

// ---------- 通信設定 ----------
String ARDUINO_IP   = "10.123.106.50";  // ★UNO R4 の IP に合わせる
int    ARDUINO_PORT = 8888;
int    LOCAL_PORT   = 9999;

DatagramSocket socket;
InetAddress    arduinoAddr;

// ---------- 2D ジョイスティック ----------
int   joyX, joyY;           // パッド中心座標
int   joySize = 240;        // パッドの一辺(px)
float dotX, dotY;           // ドット現在位置
boolean draggingJoy = false;

int   leftVal  = 0;         // -100〜100
int   rightVal = 0;         // -100〜100

// ---------- ボタン ----------
boolean running = false;
int   btnY = 415, btnH = 55;

volatile String lastAck = "(まだ受信なし)";

// ============================================================
void setup() {
  size(600, 510);
  textAlign(CENTER, CENTER);
  joyX = width / 2;
  joyY = 210;
  dotX = joyX;
  dotY = joyY;
  try {
    socket     = new DatagramSocket(LOCAL_PORT);
    arduinoAddr = InetAddress.getByName(ARDUINO_IP);
  } catch (Exception e) {
    println("ソケット初期化エラー: " + e.getMessage());
  }
  thread("receiveLoop");
}

// ============================================================
void draw() {
  background(28, 30, 36);

  // タイトル
  fill(235);
  textSize(22);
  text("2モーター同時コントロール", width/2, 36);

  // ジョイスティックパッド
  drawJoypad();

  // 左右モーター値
  drawMotorValue(80,  370, "左モーター", leftVal);
  drawMotorValue(520, 370, "右モーター", rightVal);

  // ボタン
  drawButton(100, btnY, 160, btnH,
             running ? color(40,120,60) : color(50,160,80), "START");
  drawButton(340, btnY, 160, btnH, color(180,60,60), "STOP");

  // ステータスバー
  textSize(12);
  fill(150);
  text("宛先 " + ARDUINO_IP + ":" + ARDUINO_PORT
       + "   " + (running ? "走行中" : "停止")
       + "   ACK: " + lastAck, width/2, 490);
}

// ---------- ジョイスティック描画 ----------
void drawJoypad() {
  float half = joySize / 2.0;

  // パッド背景
  noStroke();
  fill(50, 55, 70);
  rectMode(CENTER);
  rect(joyX, joyY, joySize, joySize, 18);
  rectMode(CORNER);

  // グリッド線 (中央十字)
  stroke(75);
  strokeWeight(1);
  line(joyX - half, joyY, joyX + half, joyY);
  line(joyX, joyY - half, joyX, joyY + half);
  noStroke();

  // ドット (走行中は青、停止中はグレー)
  color dotColor = running ? color(80, 200, 255) : color(170, 175, 185);
  fill(dotColor);
  ellipse(dotX, dotY, 48, 48);
  // ドット内十字
  stroke(255, 180);
  strokeWeight(2);
  line(dotX - 12, dotY, dotX + 12, dotY);
  line(dotX, dotY - 12, dotX, dotY + 12);
  noStroke();

  // 方向ラベル
  fill(140);
  textSize(13);
  text("前進 ↑",           joyX,            joyY - half - 16);
  text("↓ 後進",           joyX,            joyY + half + 16);
  text("←",               joyX - half - 22, joyY - 10);
  text("左折",             joyX - half - 22, joyY + 10);
  text("→",               joyX + half + 22, joyY - 10);
  text("右折",             joyX + half + 22, joyY + 10);
}

// ---------- モーター値表示 ----------
void drawMotorValue(int cx, int cy, String label, int val) {
  color c = val >= 0 ? color(80,200,255) : color(255,140,80);
  fill(180);
  textSize(14);
  text(label, cx, cy - 24);
  fill(c);
  textSize(34);
  text(val + "", cx, cy + 10);
}

// ---------- ボタン描画 ----------
void drawButton(int x, int y, int w, int h, color c, String label) {
  fill(c);
  rect(x, y, w, h, 12);
  fill(255);
  textSize(20);
  text(label, x + w/2, y + h/2);
}

// ============================================================
// マウス操作
// ============================================================
void mousePressed() {
  if (overJoy()) {
    draggingJoy = true;
    updateJoy();
    return;
  }
  // START ボタン
  if (overRect(100, btnY, 160, btnH)) {
    running = true;
    sendUDP("RUN:1");
  }
  // STOP ボタン: 走行停止 + 値リセット
  if (overRect(340, btnY, 160, btnH)) {
    running = false;
    leftVal = 0;
    rightVal = 0;
    resetDot();
    sendUDP("RUN:0");
    sendLR();
  }
}

void mouseDragged()  { if (draggingJoy) updateJoy(); }

void mouseReleased() {
  if (draggingJoy) {
    draggingJoy = false;
    // 離したらセンターに戻して停止
    resetDot();
    sendLR();
  }
}

// ---------- ジョイスティック範囲判定 ----------
boolean overJoy() {
  float half = joySize / 2.0;
  return mouseX > joyX - half && mouseX < joyX + half
      && mouseY > joyY - half && mouseY < joyY + half;
}

boolean overRect(int x, int y, int w, int h) {
  return mouseX > x && mouseX < x + w && mouseY > y && mouseY < y + h;
}

// ---------- ジョイスティック更新 ----------
void updateJoy() {
  float half = joySize / 2.0;
  dotX = constrain(mouseX, joyX - half, joyX + half);
  dotY = constrain(mouseY, joyY - half, joyY + half);

  // 正規化 (-1.0 〜 1.0)
  float nx =  (dotX - joyX) / half;   // 右+ = 右折
  float ny =  (dotY - joyY) / half;   // 下+ (前進は上なので後で反転)

  int forward = (int)(-ny * 100);     // 上=前進(+)
  int steer   = (int)( nx * 100);     // 右折(+)

  leftVal  = constrain(forward + steer, -100, 100);
  rightVal = constrain(forward - steer, -100, 100);
  sendLR();
}

void resetDot() {
  dotX = joyX;
  dotY = joyY;
  leftVal  = 0;
  rightVal = 0;
}

// ============================================================
// キー操作
// ============================================================
void keyPressed() {
  if (key == ' ') {
    running = !running;
    sendUDP(running ? "RUN:1" : "RUN:0");
  }
  if (key == 's' || key == 'S') {
    leftVal = 0;
    rightVal = 0;
    resetDot();
    sendLR();
  }
}

// ============================================================
// UDP 送受信
// ============================================================
void sendLR() {
  sendUDP("LR:" + leftVal + "," + rightVal);
}

void sendUDP(String msg) {
  if (socket == null || arduinoAddr == null) return;
  try {
    byte[] buf = msg.getBytes();
    socket.send(new DatagramPacket(buf, buf.length, arduinoAddr, ARDUINO_PORT));
    println("send -> " + msg);
  } catch (Exception e) {
    println("送信エラー: " + e.getMessage());
  }
}

void receiveLoop() {
  byte[] buf = new byte[256];
  while (true) {
    if (socket == null) { delay(100); continue; }
    try {
      DatagramPacket pkt = new DatagramPacket(buf, buf.length);
      socket.receive(pkt);
      lastAck = new String(pkt.getData(), 0, pkt.getLength());
    } catch (Exception e) {
      delay(50);
    }
  }
}
