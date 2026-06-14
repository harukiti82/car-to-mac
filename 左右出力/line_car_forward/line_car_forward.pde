/**
 * ============================================================
 *  ラインカー リモコン  ―  前進・BPM指定
 *  Processing → Arduino UNO R4 WiFi（UDP）
 * ============================================================
 *  操作:
 *    スライダーをドラッグ  上=速い / 下=停止
 *    BPMフィールドをクリック → 数字キーで入力 → Enter で確定
 *    離しても設定BPMを維持して走り続ける
 *    STOP ボタン: 即時停止してノブを0に戻す
 *
 *  BPM対応表（speed_bpm_table.pdf 準拠）:
 *    BPM  40: v < 0.085 m/s
 *    BPM  65: 0.085 ≤ v < 0.120
 *    BPM  90: 0.120 ≤ v < 0.155
 *    BPM 115: 0.155 ≤ v < 0.190
 *    BPM 140: 0.190 ≤ v < 0.225
 *    BPM 165: 0.225 ≤ v < 0.260
 *    BPM 190: 0.260 ≤ v < 0.295
 *    BPM 215: 0.295 ≤ v < 0.330
 *    BPM 240: 0.330 ≤ v
 *
 *  プロトコル:
 *    "LR:<speed>,<speed>"  左右同値で送信（前進のみ）
 *    "STOP"
 * ============================================================
 */

import java.net.*;

// ---- 通信設定 ----
final String ARDUINO_IP   = "192.168.4.1";
final int    ARDUINO_PORT = 8888;

DatagramSocket udpSocket;
InetAddress    arduinoAddr;

// ---- BPM対応表 ----
final int[] BPM_STEPS = {40, 65, 90, 115, 140, 165, 190, 215, 240};

// ---- レイアウト定数 ----
final int W = 300;
final int H = 570;

final int SLIDER_X      = W / 2 - 20;
final int SLIDER_TOP    = 100;
final int SLIDER_BOTTOM = 360;
final int KNOB_R        = 24;

final int FIELD_Y = 435;
final int FIELD_W = 160;
final int FIELD_H = 36;

final int BTN_X = W / 2;
final int BTN_Y = 510;
final int BTN_W = 130;
final int BTN_H = 44;

// ---- 状態 ----
float   knobY      = SLIDER_BOTTOM;
boolean dragging   = false;
int     currentBpm = 0;  // 0=停止, 40〜240=走行

// ---- テキスト入力 ----
String  inputText    = "";
boolean inputFocused = false;

// ---- 送信タイミング ----
int lastSendMs = 0;
final int SEND_INTERVAL = 50;

// ============================================================
void setup() {
  size(300, 570);
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

  if (millis() - lastSendMs > SEND_INTERVAL) {
    sendSpeed();
    lastSendMs = millis();
  }

  drawTitle();
  drawSlider();
  drawSpeedLabel();
  drawInputField();
  drawStopButton();
}

// ---- タイトル ----
void drawTitle() {
  fill(180);
  noStroke();
  textSize(14);
  text("ラインカー リモコン  BPM指定", W / 2, 30);

  fill(80);
  textSize(11);
  text(ARDUINO_IP + "  :" + ARDUINO_PORT, W / 2, 50);
}

// ---- スライダー描画 ----
void drawSlider() {
  stroke(60);
  strokeWeight(8);
  line(SLIDER_X, SLIDER_TOP, SLIDER_X, SLIDER_BOTTOM);

  if (knobY > SLIDER_TOP) {
    stroke(50, 180, 100);
    strokeWeight(8);
    line(SLIDER_X, SLIDER_TOP, SLIDER_X, knobY);
  }

  noStroke();
  fill(100, 200, 120);
  textSize(12);
  text("▲ 速い", SLIDER_X, SLIDER_TOP - 22);

  fill(140);
  text("▼ 停止", SLIDER_X, SLIDER_BOTTOM + 22);

  if (dragging) {
    noStroke();
    fill(50, 200, 100, 50);
    ellipse(SLIDER_X, knobY, KNOB_R * 3.4, KNOB_R * 3.4);
  }

  color knobFill = (currentBpm == 0) ? color(110) : color(50, 200, 100);
  fill(knobFill);
  stroke(220, 100);
  strokeWeight(2);
  ellipse(SLIDER_X, knobY, KNOB_R * 2, KNOB_R * 2);

  drawBpmTicks();
}

// ---- BPM目盛り ----
void drawBpmTicks() {
  for (int bpm : BPM_STEPS) {
    float y = map(bpm, 0, 240, SLIDER_BOTTOM, SLIDER_TOP);
    stroke(70);
    strokeWeight(1);
    line(SLIDER_X + KNOB_R + 6, y, SLIDER_X + KNOB_R + 16, y);
    noStroke();
    fill(100);
    textSize(10);
    textAlign(LEFT, CENTER);
    text(bpm, SLIDER_X + KNOB_R + 19, y);
  }
  textAlign(CENTER, CENTER);
}

// ---- 速度テキスト ----
void drawSpeedLabel() {
  noStroke();
  if (currentBpm == 0) {
    fill(140);
    textSize(20);
    text("停止", W / 2, 390);
  } else {
    fill(50, 200, 100);
    textSize(20);
    text("前進  BPM " + currentBpm, W / 2, 390);
    fill(90);
    textSize(11);
    text("(speed " + bpmToSpeedPct(currentBpm) + "%)", W / 2, 412);
  }
}

// ---- テキスト入力フィールド ----
void drawInputField() {
  fill(120);
  noStroke();
  textSize(11);
  text("BPMを直接入力（40〜240 / 0=停止）", W / 2, FIELD_Y - 24);

  fill(inputFocused ? color(48) : color(38));
  stroke(inputFocused ? color(80, 160, 255) : color(75));
  strokeWeight(2);
  rect(W / 2 - FIELD_W / 2, FIELD_Y - FIELD_H / 2, FIELD_W, FIELD_H, 7);

  fill(255);
  noStroke();
  textSize(17);
  String cursor = (inputFocused && frameCount % 50 < 25) ? "|" : "";
  text(inputText + cursor + "  BPM", W / 2, FIELD_Y);
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

boolean overField(int mx, int my) {
  return mx > W / 2 - FIELD_W / 2 && mx < W / 2 + FIELD_W / 2 &&
         my > FIELD_Y - FIELD_H / 2 && my < FIELD_Y + FIELD_H / 2;
}

// ============================================================
//  マウス操作
// ============================================================
void mousePressed() {
  if (overButton(mouseX, mouseY)) {
    execStop();
    inputFocused = false;
    return;
  }

  if (overField(mouseX, mouseY)) {
    inputFocused = true;
    inputText    = "";
    return;
  }

  inputFocused = false;

  if (abs(mouseX - SLIDER_X) < 36 &&
      mouseY > SLIDER_TOP - KNOB_R &&
      mouseY < SLIDER_BOTTOM + KNOB_R) {
    dragging   = true;
    knobY      = constrain(mouseY, SLIDER_TOP, SLIDER_BOTTOM);
    currentBpm = knobYToBpm(knobY);
  }
}

void mouseDragged() {
  if (!dragging) return;
  knobY      = constrain(mouseY, SLIDER_TOP, SLIDER_BOTTOM);
  currentBpm = knobYToBpm(knobY);
}

void mouseReleased() {
  dragging = false;
}

// ============================================================
//  キーボード入力
// ============================================================
void keyPressed() {
  // 矢印キー↑↓: BPMステップ切り替え（フォーカス外でも動作）
  if (key == CODED) {
    if (keyCode == UP) {
      stepBpm(+1);
    } else if (keyCode == DOWN) {
      stepBpm(-1);
    }
    return;
  }

  if (key == ' ') {
    execStop();
    return;
  }

  if (!inputFocused) return;

  if (key >= '0' && key <= '9') {
    if (inputText.length() < 3) {
      inputText += key;
    }
  } else if (key == BACKSPACE) {
    if (inputText.length() > 0) {
      inputText = inputText.substring(0, inputText.length() - 1);
    }
  } else if (key == ENTER || key == RETURN) {
    applyInput();
  } else if (key == ESC) {
    key          = 0;
    inputText    = "";
    inputFocused = false;
  }
}

void applyInput() {
  if (inputText.length() > 0) {
    int val = Integer.parseInt(inputText);
    if (val == 0) {
      currentBpm = 0;
    } else {
      currentBpm = constrain(val, 40, 240);
    }
    knobY = bpmToKnobY(currentBpm);
  }
  inputText    = "";
  inputFocused = false;
}

// ============================================================
//  BPMステップ切り替え（矢印キー用）
//  dir=+1 で1段階上、dir=-1 で1段階下（0=停止を含む）
// ============================================================
void stepBpm(int dir) {
  int idx = -1;  // -1 = 停止(BPM 0)
  for (int i = 0; i < BPM_STEPS.length; i++) {
    if (currentBpm >= BPM_STEPS[i]) idx = i;
  }
  idx += dir;
  if (idx < 0) {
    currentBpm = 0;
  } else {
    currentBpm = BPM_STEPS[constrain(idx, 0, BPM_STEPS.length - 1)];
  }
  knobY = bpmToKnobY(currentBpm);
}

// ============================================================
//  BPM ↔ knobY 変換
// ============================================================
int knobYToBpm(float y) {
  int raw = (int) map(y, SLIDER_BOTTOM, SLIDER_TOP, 0, 240);
  if (raw < 20) return 0;
  return constrain(raw, 40, 240);
}

float bpmToKnobY(int bpm) {
  return map(bpm, 0, 240, SLIDER_BOTTOM, SLIDER_TOP);
}

// ============================================================
//  BPM → speed% 変換（Arduino送信用）
//  BPM 40〜240 → speed 20〜100 にリニアマッピング
// ============================================================
int bpmToSpeedPct(int bpm) {
  if (bpm <= 0) return 0;
  return (int) map(constrain(bpm, 40, 240), 40, 240, 20, 100);
}

// ============================================================
//  送信処理
// ============================================================
void sendSpeed() {
  if (currentBpm == 0) {
    udpSend("STOP");
  } else {
    int spd = bpmToSpeedPct(currentBpm);
    udpSend("LR:" + spd + "," + spd);
  }
}

void execStop() {
  currentBpm = 0;
  knobY      = SLIDER_BOTTOM;
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
