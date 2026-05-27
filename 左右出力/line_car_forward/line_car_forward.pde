/**
 * ============================================================
 *  ラインカー リモコン  ―  前進・速度のみ
 *  Processing → Arduino UNO R4 WiFi（UDP）
 * ============================================================
 *  操作:
 *    スライダーをドラッグ  上=速い / 下=遅い（0=停止）
 *    離しても設定速度を維持して走り続ける
 *    STOP ボタン: 即時停止してノブを0に戻す
 *
 *  プロトコル:
 *    "LR:<speed>,<speed>"  左右同値で送信（前進のみ）
 *    "RUN:1" / "RUN:0"
 *    "STOP"
 * ============================================================
 */

import java.net.*;

// ---- 通信設定 ----
final String ARDUINO_IP   = "10.123.106.50";
final int    ARDUINO_PORT = 8888;

DatagramSocket udpSocket;
InetAddress    arduinoAddr;

// ---- レイアウト定数 ----
final int W = 300;
final int H = 520;

final int SLIDER_X      = W / 2;
final int SLIDER_TOP    = 100;  // 上端（速度MAX = 100%）
final int SLIDER_BOTTOM = 390;  // 下端（速度MIN = 0%）
final int KNOB_R        = 24;

final int BTN_X = W / 2;
final int BTN_Y = 460;
final int BTN_W = 130;
final int BTN_H = 44;

// ---- 状態 ----
float   knobY    = SLIDER_BOTTOM;  // 初期位置: 最下端（速度0）
boolean dragging = false;
int     speedPct = 0;  // 0〜100

// ---- 送信タイミング ----
int lastSendMs = 0;
final int SEND_INTERVAL = 50;  // 20 Hz

// ============================================================
void setup() {
  size(300, 520);
  textAlign(CENTER, CENTER);
  smooth();

  try {
    udpSocket   = new DatagramSocket();
    arduinoAddr = InetAddress.getByName(ARDUINO_IP);
    println("UDP ready → " + ARDUINO_IP + ":" + ARDUINO_PORT);
  } catch (Exception e) {
    println("UDP 初期化エラー: " + e.getMessage());
  }
}

// ============================================================
void draw() {
  background(28);

  // 一定間隔で速度コマンドを送信
  if (millis() - lastSendMs > SEND_INTERVAL) {
    sendSpeed();
    lastSendMs = millis();
  }

  drawTitle();
  drawSlider();
  drawSpeedLabel();
  drawStopButton();
}

// ---- タイトル ----
void drawTitle() {
  fill(180);
  noStroke();
  textSize(14);
  text("ラインカー リモコン  前進専用", SLIDER_X, 30);

  fill(80);
  textSize(11);
  text(ARDUINO_IP + "  :" + ARDUINO_PORT, SLIDER_X, 50);
}

// ---- スライダー描画 ----
void drawSlider() {
  // レール（背景）
  stroke(60);
  strokeWeight(8);
  line(SLIDER_X, SLIDER_TOP, SLIDER_X, SLIDER_BOTTOM);

  // 速度に応じてノブより上を緑で塗る
  if (knobY > SLIDER_TOP) {
    stroke(50, 180, 100);
    strokeWeight(8);
    line(SLIDER_X, SLIDER_TOP, SLIDER_X, knobY);
  }

  // 上端ラベル（速い）
  noStroke();
  fill(100, 200, 120);
  textSize(13);
  text("▲  速い", SLIDER_X, SLIDER_TOP - 22);

  // 下端ラベル（遅い）
  fill(140);
  text("▼  遅い", SLIDER_X, SLIDER_BOTTOM + 22);

  // ノブのグロー（ドラッグ中）
  if (dragging) {
    noStroke();
    fill(50, 200, 100, 50);
    ellipse(SLIDER_X, knobY, KNOB_R * 3.4, KNOB_R * 3.4);
  }

  // ノブ本体（速度0のとき灰色、それ以外は緑）
  color knobFill = (speedPct == 0) ? color(110) : color(50, 200, 100);
  fill(knobFill);
  stroke(220, 100);
  strokeWeight(2);
  ellipse(SLIDER_X, knobY, KNOB_R * 2, KNOB_R * 2);
}

// ---- 速度テキスト ----
void drawSpeedLabel() {
  noStroke();
  color col = (speedPct == 0) ? color(140) : color(50, 200, 100);
  fill(col);
  textSize(20);
  text((speedPct == 0 ? "停止" : "前進") + "  " + speedPct + "%", SLIDER_X, 422);
}

// ---- STOP ボタン ----
void drawStopButton() {
  boolean hover = overButton(mouseX, mouseY);
  fill(hover ? color(230, 50, 50) : color(160, 35, 35));
  noStroke();
  rect(BTN_X - BTN_W / 2, BTN_Y - BTN_H / 2, BTN_W, BTN_H, 10);
  fill(255);
  textSize(17);
  text("■  STOP", BTN_X, BTN_Y);
}

boolean overButton(int mx, int my) {
  return mx > BTN_X - BTN_W / 2 && mx < BTN_X + BTN_W / 2 &&
         my > BTN_Y - BTN_H / 2 && my < BTN_Y + BTN_H / 2;
}

// ============================================================
//  マウス操作
// ============================================================
void mousePressed() {
  // STOP ボタン
  if (overButton(mouseX, mouseY)) {
    execStop();
    return;
  }

  // スライダーレール付近ならどこでもドラッグ開始
  if (abs(mouseX - SLIDER_X) < 36 &&
      mouseY > SLIDER_TOP - KNOB_R &&
      mouseY < SLIDER_BOTTOM + KNOB_R) {
    dragging = true;
    knobY    = constrain(mouseY, SLIDER_TOP, SLIDER_BOTTOM);
    speedPct = (int) map(knobY, SLIDER_BOTTOM, SLIDER_TOP, 0, 100);
  }
}

void mouseDragged() {
  if (!dragging) return;
  knobY    = constrain(mouseY, SLIDER_TOP, SLIDER_BOTTOM);
  speedPct = (int) map(knobY, SLIDER_BOTTOM, SLIDER_TOP, 0, 100);
}

void mouseReleased() {
  // 離してもノブはその位置のまま、速度を維持
  dragging = false;
}

// ============================================================
//  送信処理
// ============================================================
void sendSpeed() {
  if (speedPct == 0) {
    udpSend("RUN:0");
  } else {
    udpSend("RUN:1");
    udpSend("LR:" + speedPct + "," + speedPct);
  }
}

void execStop() {
  speedPct = 0;
  knobY    = SLIDER_BOTTOM;  // ノブを最下端（0%）に戻す
  udpSend("STOP");
}

void udpSend(String msg) {
  if (udpSocket == null || arduinoAddr == null) return;
  try {
    byte[] data = msg.getBytes("UTF-8");
    DatagramPacket pkt = new DatagramPacket(data, data.length, arduinoAddr, ARDUINO_PORT);
    udpSocket.send(pkt);
    println("→ " + msg);
  } catch (Exception e) {
    println("UDP 送信エラー: " + e.getMessage());
  }
}
