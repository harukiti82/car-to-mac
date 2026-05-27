/**
 * ============================================================
 *  ラインカー リモコン  ―  前後・速度のみ
 *  Processing → Arduino UNO R4 WiFi（UDP）
 * ============================================================
 *  操作:
 *    スライダーをドラッグ  上=前進 / 下=後退
 *    量で速度が変わる（中央=停止）
 *    離した瞬間にノブが中央へ戻り、自動停止
 *    STOP ボタン: 即時停止
 *
 *  プロトコル:
 *    "LR:<left>,<right>"  前後は左右同値で送信
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
final int SLIDER_TOP    = 100;   // 上端（前進MAX）
final int SLIDER_BOTTOM = 390;   // 下端（後退MAX）
final int SLIDER_CENTER = (SLIDER_TOP + SLIDER_BOTTOM) / 2;  // 245
final int KNOB_R        = 24;

final int BTN_X  = W / 2;
final int BTN_Y  = 460;
final int BTN_W  = 130;
final int BTN_H  = 44;

// ---- 状態 ----
float   knobY    = SLIDER_CENTER;
boolean dragging = false;
int     speedPct = 0;  // -100〜100（正=前進，負=後退）

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
  text("ラインカー リモコン", SLIDER_X, 30);

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

  // 前進側レール（ノブより上）
  if (knobY > SLIDER_CENTER) {
    // 後退側を赤で
    stroke(180, 60, 50);
    strokeWeight(8);
    line(SLIDER_X, SLIDER_CENTER, SLIDER_X, knobY);
  } else if (knobY < SLIDER_CENTER) {
    // 前進側を緑で
    stroke(50, 180, 100);
    strokeWeight(8);
    line(SLIDER_X, knobY, SLIDER_X, SLIDER_CENTER);
  }

  // 中央ゼロマーク
  stroke(120);
  strokeWeight(2);
  line(SLIDER_X - 16, SLIDER_CENTER, SLIDER_X + 16, SLIDER_CENTER);

  // 前進 / 後退ラベル
  noStroke();
  fill(100, 200, 120);
  textSize(13);
  text("▲  前進", SLIDER_X, SLIDER_TOP - 22);

  fill(200, 100, 80);
  text("▼  後退", SLIDER_X, SLIDER_BOTTOM + 22);

  // ノブ
  color knobFill;
  float t = map(knobY, SLIDER_TOP, SLIDER_BOTTOM, 1.0, -1.0);
  if (abs(t) < 0.04) {
    knobFill = color(110);
  } else if (t > 0) {
    knobFill = color(50, 200, 100);
  } else {
    knobFill = color(220, 80, 60);
  }

  // ノブのグロー（ドラッグ中）
  if (dragging) {
    noStroke();
    fill(red(knobFill), green(knobFill), blue(knobFill), 50);
    ellipse(SLIDER_X, knobY, KNOB_R * 3.4, KNOB_R * 3.4);
  }

  fill(knobFill);
  stroke(220, 100);
  strokeWeight(2);
  ellipse(SLIDER_X, knobY, KNOB_R * 2, KNOB_R * 2);
}

// ---- 速度テキスト ----
void drawSpeedLabel() {
  noStroke();
  String dir;
  color  col;

  if (speedPct > 0)      { dir = "前進";  col = color(50, 200, 100); }
  else if (speedPct < 0) { dir = "後退";  col = color(220, 80,  60); }
  else                   { dir = "停止";  col = color(140);           }

  fill(col);
  textSize(18);
  text(dir + "  " + abs(speedPct) + "%", SLIDER_X, 425);
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
    speedPct = (int) map(knobY, SLIDER_TOP, SLIDER_BOTTOM, 100, -100);
  }
}

void mouseDragged() {
  if (!dragging) return;
  knobY    = constrain(mouseY, SLIDER_TOP, SLIDER_BOTTOM);
  speedPct = (int) map(knobY, SLIDER_TOP, SLIDER_BOTTOM, 100, -100);
}

void mouseReleased() {
  if (dragging) {
    dragging = false;
    execStop();
  }
}

// ============================================================
//  送信処理
// ============================================================
void sendSpeed() {
  if (speedPct == 0) {
    udpSend("RUN:0");
  } else {
    // 前後は左右を同値で送る
    udpSend("RUN:1");
    udpSend("LR:" + speedPct + "," + speedPct);
  }
}

void execStop() {
  speedPct = 0;
  knobY    = SLIDER_CENTER;
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
