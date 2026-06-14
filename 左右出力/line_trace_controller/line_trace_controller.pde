/**
 * ============================================================
 *  ライントレース統合リモコン
 *  Processing → Arduino UNO R4 WiFi（UDP）
 * ============================================================
 *  対応プロトコル:
 *    "MODE:AUTO"            ライントレースモード（ESP32 誤差で自動操舵）
 *    "MODE:MANUAL"          手動モード（左右スライダーで直接操作）
 *    "SPD:<0..100>"         AUTO 時のベース速度
 *    "LR:<left>,<right>"    MANUAL 時の左右速度 (-100〜100)
 *    "RUN:1" / "RUN:0"      走行開始 / 停止
 *    "STOP"                 即時停止
 *
 *  操作:
 *    [AUTO] ボタン → ESP32 ライントレース制御
 *      SPD スライダー / 数値入力でベース速度を設定
 *      [RUN] ボタンで走行開始
 *    [MANUAL] ボタン → 左右スライダーで直接操縦
 *      左スライダー = 左車輪速度、右スライダー = 右車輪速度
 *    [STOP] ボタン: どのモードでも即時停止
 * ============================================================
 */

import java.net.*;

// ---- 通信設定 ----
final String ARDUINO_IP   = "192.168.4.1";
final int    ARDUINO_PORT = 8888;

DatagramSocket udpSocket;
InetAddress    arduinoAddr;

// ---- ウィンドウサイズ ----
final int W = 380;
final int H = 680;

// ---- モード ----
// true=AUTO（ライントレース）、false=MANUAL（手動）
boolean autoMode = false;
// 走行中フラグ（AUTO時のみ使用。MANUAL は常時送信）
boolean running  = false;

// ---- AUTO モード用 ----
int     spdPct      = 0;      // 0〜100
float   spdKnobY    = 0;      // スライダーノブY（setup で初期化）
boolean spdDragging = false;

// ---- SPD 直接入力 ----
String  spdInput      = "";
boolean spdFocused    = false;

// ---- MANUAL モード用（左右スライダー） ----
int   leftPct       = 0;    // -100〜100
int   rightPct      = 0;    // -100〜100
float leftKnobY     = 0;    // setup で初期化
float rightKnobY    = 0;
boolean leftDragging  = false;
boolean rightDragging = false;

// ---- ACK 表示 ----
String  ackText    = "---";
int     ackColorR  = 100;
int     ackColorG  = 100;
int     ackColorB  = 100;
long    ackTime    = 0;
DatagramSocket recvSocket;
Thread  recvThread;

// ---- 送信タイミング ----
long lastSendMs    = 0;
final int SEND_INTERVAL = 50;  // 20 Hz

// ============================================================
//  レイアウト定数
// ============================================================
// --- モードボタン ---
final int MODE_BTN_Y  = 60;
final int MODE_BTN_W  = 140;
final int MODE_BTN_H  = 44;
final int AUTO_BTN_X  = W / 2 - 76;
final int MAN_BTN_X   = W / 2 + 76;

// --- AUTO: SPDスライダー ---
final int SPD_X          = W / 2;
final int SPD_TOP        = 148;
final int SPD_BOTTOM     = 360;
final int SPD_KNOB_R     = 22;

// --- SPD 直接入力フィールド ---
final int SPD_FIELD_Y  = 402;
final int SPD_FIELD_W  = 160;
final int SPD_FIELD_H  = 36;

// --- MANUAL: 左右スライダー ---
final int LR_TOP         = 148;
final int LR_BOTTOM      = 420;
final int LR_CENTER      = (LR_TOP + LR_BOTTOM) / 2;
final int LR_KNOB_R      = 22;
final int LEFT_SLIDER_X  = W / 2 - 60;
final int RIGHT_SLIDER_X = W / 2 + 60;

// --- RUN ボタン ---
final int RUN_BTN_X = W / 2 - 76;
final int RUN_BTN_Y = 490;
final int RUN_BTN_W = 120;
final int RUN_BTN_H = 44;

// --- STOP ボタン ---
final int STOP_BTN_X = W / 2 + 76;
final int STOP_BTN_Y = 490;
final int STOP_BTN_W = 120;
final int STOP_BTN_H = 44;

// --- ステータス表示 ---
final int STATUS_Y = 560;
final int ACK_Y    = 610;

// ============================================================
void setup() {
  size(380, 680);
  textAlign(CENTER, CENTER);
  smooth();

  // スライダーノブ初期位置
  spdKnobY   = SPD_BOTTOM;    // 速度 0
  leftKnobY  = LR_CENTER;     // 左 0
  rightKnobY = LR_CENTER;     // 右 0

  // UDP 送信ソケット
  try {
    udpSocket   = new DatagramSocket();
    arduinoAddr = InetAddress.getByName(ARDUINO_IP);
    println("UDP 送信 ready → " + ARDUINO_IP + ":" + ARDUINO_PORT);
  } catch (Exception e) {
    println("UDP 初期化エラー: " + e.getMessage());
  }

  // ACK 受信ソケット（別ポートで受信）
  try {
    recvSocket = new DatagramSocket(ARDUINO_PORT);
    recvThread = new Thread(new Runnable() {
      public void run() {
        byte[] buf = new byte[128];
        while (true) {
          try {
            DatagramPacket pkt = new DatagramPacket(buf, buf.length);
            recvSocket.receive(pkt);
            String msg = new String(pkt.getData(), 0, pkt.getLength(), "UTF-8").trim();
            ackText   = msg.length() > 50 ? msg.substring(0, 50) : msg;
            ackColorR = 60; ackColorG = 200; ackColorB = 100;
            ackTime   = System.currentTimeMillis();
          } catch (Exception e) { /* ignore */ }
        }
      }
    });
    recvThread.setDaemon(true);
    recvThread.start();
    println("ACK 受信 ready on port " + ARDUINO_PORT);
  } catch (Exception e) {
    println("ACK 受信ソケット失敗（既に使用中の可能性）: " + e.getMessage());
  }
}

// ============================================================
void draw() {
  background(28);

  // 一定間隔でコマンド送信
  if (millis() - lastSendMs > SEND_INTERVAL) {
    sendCommand();
    lastSendMs = millis();
  }

  // ACK が 2 秒以上来なかったら色を暗くする
  if (System.currentTimeMillis() - ackTime > 2000) {
    ackColorR = 80; ackColorG = 80; ackColorB = 80;
  }

  drawTitle();
  drawModeButtons();

  if (autoMode) {
    drawSpdSlider();
    drawSpdInputField();
  } else {
    drawLRSliders();
  }

  drawRunStopButtons();
  drawStatus();
}

// ============================================================
//  描画
// ============================================================
void drawTitle() {
  fill(180);
  noStroke();
  textSize(14);
  text("ライントレース 統合リモコン", W / 2, 22);
  fill(70);
  textSize(11);
  text(ARDUINO_IP + "  :" + ARDUINO_PORT, W / 2, 40);
}

// ---- モードボタン ----
void drawModeButtons() {
  // AUTO ボタン
  boolean autoHover = overRect(mouseX, mouseY, AUTO_BTN_X, MODE_BTN_Y, MODE_BTN_W, MODE_BTN_H);
  if (autoMode) {
    fill(40, 160, 80);
  } else {
    fill(autoHover ? color(55, 90, 65) : color(40, 55, 45));
  }
  noStroke();
  rect(AUTO_BTN_X - MODE_BTN_W / 2, MODE_BTN_Y - MODE_BTN_H / 2, MODE_BTN_W, MODE_BTN_H, 8);
  fill(autoMode ? 255 : 140);
  textSize(15);
  text("AUTO", AUTO_BTN_X, MODE_BTN_Y);

  // MANUAL ボタン
  boolean manHover = overRect(mouseX, mouseY, MAN_BTN_X, MODE_BTN_Y, MODE_BTN_W, MODE_BTN_H);
  if (!autoMode) {
    fill(60, 100, 200);
  } else {
    fill(manHover ? color(50, 60, 100) : color(38, 45, 80));
  }
  noStroke();
  rect(MAN_BTN_X - MODE_BTN_W / 2, MODE_BTN_Y - MODE_BTN_H / 2, MODE_BTN_W, MODE_BTN_H, 8);
  fill(!autoMode ? 255 : 140);
  textSize(15);
  text("MANUAL", MAN_BTN_X, MODE_BTN_Y);

  // 区切り線
  stroke(50);
  strokeWeight(1);
  line(20, MODE_BTN_Y + MODE_BTN_H / 2 + 14, W - 20, MODE_BTN_Y + MODE_BTN_H / 2 + 14);
}

// ---- AUTO: SPD スライダー ----
void drawSpdSlider() {
  // レール
  stroke(60);
  strokeWeight(8);
  line(SPD_X, SPD_TOP, SPD_X, SPD_BOTTOM);

  // 速度に応じて緑で塗る
  if (spdKnobY > SPD_TOP) {
    stroke(50, 180, 100);
    strokeWeight(8);
    line(SPD_X, SPD_TOP, SPD_X, spdKnobY);
  }

  // ラベル
  noStroke();
  fill(100, 200, 120);
  textSize(13);
  text("▲  速い", SPD_X, SPD_TOP - 22);
  fill(140);
  text("▼  遅い", SPD_X, SPD_BOTTOM + 22);

  // ノブのグロー
  if (spdDragging) {
    noStroke();
    fill(50, 200, 100, 50);
    ellipse(SPD_X, spdKnobY, SPD_KNOB_R * 3.2, SPD_KNOB_R * 3.2);
  }

  // ノブ
  fill(spdPct == 0 ? color(100) : color(50, 200, 100));
  stroke(220, 100);
  strokeWeight(2);
  ellipse(SPD_X, spdKnobY, SPD_KNOB_R * 2, SPD_KNOB_R * 2);

  // 速度表示
  noStroke();
  fill(spdPct == 0 ? color(130) : color(50, 200, 100));
  textSize(20);
  text("SPD  " + spdPct + "%", SPD_X, (SPD_BOTTOM + SPD_TOP) / 2 + 110);
}

// ---- AUTO: SPD 入力フィールド ----
void drawSpdInputField() {
  fill(110);
  noStroke();
  textSize(11);
  text("速度を直接入力（0〜100）", SPD_X, SPD_FIELD_Y - 24);

  fill(spdFocused ? color(48) : color(38));
  stroke(spdFocused ? color(80, 160, 255) : color(75));
  strokeWeight(2);
  rect(SPD_X - SPD_FIELD_W / 2, SPD_FIELD_Y - SPD_FIELD_H / 2, SPD_FIELD_W, SPD_FIELD_H, 7);

  fill(255);
  noStroke();
  textSize(17);
  String cursor = (spdFocused && frameCount % 50 < 25) ? "|" : "";
  text(spdInput + cursor + "  %", SPD_X, SPD_FIELD_Y);
}

// ---- MANUAL: 左右スライダー ----
void drawLRSliders() {
  // 左スライダー
  drawLRSlider(LEFT_SLIDER_X,  leftKnobY,  leftPct,  leftDragging,  "左");
  // 右スライダー
  drawLRSlider(RIGHT_SLIDER_X, rightKnobY, rightPct, rightDragging, "右");

  // 左右速度表示
  noStroke();
  textSize(13);
  fill(speedColor(leftPct));
  text(dirLabel(leftPct) + " " + abs(leftPct) + "%", LEFT_SLIDER_X, LR_BOTTOM + 50);
  fill(speedColor(rightPct));
  text(dirLabel(rightPct) + " " + abs(rightPct) + "%", RIGHT_SLIDER_X, LR_BOTTOM + 50);

  // 注記
  fill(80);
  textSize(11);
  text("離すと自動停止", W / 2, LR_BOTTOM + 75);
}

void drawLRSlider(int sx, float ky, int pct, boolean drag, String label) {
  // レール
  stroke(60);
  strokeWeight(8);
  line(sx, LR_TOP, sx, LR_BOTTOM);

  // 中央ゼロマーク
  stroke(100);
  strokeWeight(1);
  line(sx - 14, LR_CENTER, sx + 14, LR_CENTER);

  // 前進/後退色
  if (ky < LR_CENTER) {
    stroke(50, 180, 100);
    strokeWeight(8);
    line(sx, ky, sx, LR_CENTER);
  } else if (ky > LR_CENTER) {
    stroke(180, 60, 50);
    strokeWeight(8);
    line(sx, LR_CENTER, sx, ky);
  }

  // ラベル
  noStroke();
  fill(label.equals("左") ? color(120, 200, 255) : color(255, 200, 100));
  textSize(13);
  text(label, sx, LR_TOP - 22);

  // ノブグロー
  if (drag) {
    noStroke();
    color c = speedColor(pct);
    fill(red(c), green(c), blue(c), 50);
    ellipse(sx, ky, LR_KNOB_R * 3.2, LR_KNOB_R * 3.2);
  }

  // ノブ
  fill(speedColor(pct));
  stroke(220, 100);
  strokeWeight(2);
  ellipse(sx, ky, LR_KNOB_R * 2, LR_KNOB_R * 2);
}

// ---- RUN / STOP ボタン ----
void drawRunStopButtons() {
  // RUN（AUTO モードのみ有効）
  boolean runHover = autoMode && overRect(mouseX, mouseY, RUN_BTN_X, RUN_BTN_Y, RUN_BTN_W, RUN_BTN_H);
  if (!autoMode) {
    fill(50);  // グレーアウト
  } else if (running) {
    fill(40, 160, 80);
  } else {
    fill(runHover ? color(60, 130, 60) : color(40, 80, 40));
  }
  noStroke();
  rect(RUN_BTN_X - RUN_BTN_W / 2, RUN_BTN_Y - RUN_BTN_H / 2, RUN_BTN_W, RUN_BTN_H, 10);
  fill(autoMode ? 255 : 100);
  textSize(16);
  text(running ? "■ 走行中" : "▶ RUN", RUN_BTN_X, RUN_BTN_Y);

  // STOP
  boolean stopHover = overRect(mouseX, mouseY, STOP_BTN_X, STOP_BTN_Y, STOP_BTN_W, STOP_BTN_H);
  fill(stopHover ? color(230, 50, 50) : color(160, 35, 35));
  noStroke();
  rect(STOP_BTN_X - STOP_BTN_W / 2, STOP_BTN_Y - STOP_BTN_H / 2, STOP_BTN_W, STOP_BTN_H, 10);
  fill(255);
  textSize(16);
  text("■ STOP", STOP_BTN_X, STOP_BTN_Y);
}

// ---- ステータス表示 ----
void drawStatus() {
  // モード・速度状態
  noStroke();
  fill(70);
  textSize(11);
  String modeStr = autoMode ? "MODE: AUTO  SPD=" + spdPct + "%  RUN=" + (running ? "ON" : "OFF")
                             : "MODE: MANUAL  L=" + leftPct + "%  R=" + rightPct + "%";
  text(modeStr, W / 2, STATUS_Y);

  // ACK 表示
  fill(ackColorR, ackColorG, ackColorB);
  textSize(11);
  text("ACK: " + ackText, W / 2, ACK_Y);
}

// ============================================================
//  マウス操作
// ============================================================
void mousePressed() {
  // モードボタン
  if (overRect(mouseX, mouseY, AUTO_BTN_X, MODE_BTN_Y, MODE_BTN_W, MODE_BTN_H)) {
    switchMode(true);
    return;
  }
  if (overRect(mouseX, mouseY, MAN_BTN_X, MODE_BTN_Y, MODE_BTN_W, MODE_BTN_H)) {
    switchMode(false);
    return;
  }

  // RUN ボタン（AUTO のみ）
  if (autoMode && overRect(mouseX, mouseY, RUN_BTN_X, RUN_BTN_Y, RUN_BTN_W, RUN_BTN_H)) {
    running = !running;
    udpSend(running ? "RUN:1" : "RUN:0");
    return;
  }

  // STOP ボタン
  if (overRect(mouseX, mouseY, STOP_BTN_X, STOP_BTN_Y, STOP_BTN_W, STOP_BTN_H)) {
    execStop();
    return;
  }

  if (autoMode) {
    // SPD フィールドのフォーカス
    if (overRect(mouseX, mouseY, SPD_X, SPD_FIELD_Y, SPD_FIELD_W, SPD_FIELD_H)) {
      spdFocused = true;
      spdInput   = "";
      return;
    }
    spdFocused = false;

    // SPD スライダー
    if (abs(mouseX - SPD_X) < 36 &&
        mouseY > SPD_TOP - SPD_KNOB_R &&
        mouseY < SPD_BOTTOM + SPD_KNOB_R) {
      spdDragging = true;
      spdKnobY    = constrain(mouseY, SPD_TOP, SPD_BOTTOM);
      spdPct      = (int) map(spdKnobY, SPD_BOTTOM, SPD_TOP, 0, 100);
    }
  } else {
    // 左スライダー
    if (abs(mouseX - LEFT_SLIDER_X) < 36 &&
        mouseY > LR_TOP - LR_KNOB_R &&
        mouseY < LR_BOTTOM + LR_KNOB_R) {
      leftDragging = true;
      leftKnobY    = constrain(mouseY, LR_TOP, LR_BOTTOM);
      leftPct      = (int) map(leftKnobY, LR_TOP, LR_BOTTOM, 100, -100);
    }
    // 右スライダー
    if (abs(mouseX - RIGHT_SLIDER_X) < 36 &&
        mouseY > LR_TOP - LR_KNOB_R &&
        mouseY < LR_BOTTOM + LR_KNOB_R) {
      rightDragging = true;
      rightKnobY    = constrain(mouseY, LR_TOP, LR_BOTTOM);
      rightPct      = (int) map(rightKnobY, LR_TOP, LR_BOTTOM, 100, -100);
    }
  }
}

void mouseDragged() {
  if (autoMode) {
    if (spdDragging) {
      spdKnobY = constrain(mouseY, SPD_TOP, SPD_BOTTOM);
      spdPct   = (int) map(spdKnobY, SPD_BOTTOM, SPD_TOP, 0, 100);
    }
  } else {
    if (leftDragging) {
      leftKnobY = constrain(mouseY, LR_TOP, LR_BOTTOM);
      leftPct   = (int) map(leftKnobY, LR_TOP, LR_BOTTOM, 100, -100);
    }
    if (rightDragging) {
      rightKnobY = constrain(mouseY, LR_TOP, LR_BOTTOM);
      rightPct   = (int) map(rightKnobY, LR_TOP, LR_BOTTOM, 100, -100);
    }
  }
}

void mouseReleased() {
  spdDragging = false;
  if (!autoMode) {
    // MANUAL: 離したら停止（バネ式）
    if (leftDragging)  { leftPct  = 0; leftKnobY  = LR_CENTER; }
    if (rightDragging) { rightPct = 0; rightKnobY = LR_CENTER; }
    leftDragging  = false;
    rightDragging = false;
  }
}

// ============================================================
//  キーボード入力（SPD フィールド）
// ============================================================
void keyPressed() {
  if (autoMode && spdFocused) {
    if (key >= '0' && key <= '9') {
      if (spdInput.length() < 3) spdInput += key;
    } else if (key == BACKSPACE) {
      if (spdInput.length() > 0) spdInput = spdInput.substring(0, spdInput.length() - 1);
    } else if (key == ENTER || key == RETURN) {
      applySpdInput();
    } else if (key == ESC) {
      key        = 0;  // ウィンドウ終了を抑制
      spdInput   = "";
      spdFocused = false;
    }
  } else if (key == ESC) {
    key = 0;  // ウィンドウ終了を抑制
  }
}

void applySpdInput() {
  if (spdInput.length() > 0) {
    int val = constrain(Integer.parseInt(spdInput), 0, 100);
    spdPct   = val;
    spdKnobY = map(val, 0, 100, SPD_BOTTOM, SPD_TOP);
  }
  spdInput   = "";
  spdFocused = false;
}

// ============================================================
//  送信処理
// ============================================================
void sendCommand() {
  if (autoMode) {
    udpSend("MODE:AUTO");
    udpSend("SPD:" + spdPct);
    udpSend(running ? "RUN:1" : "RUN:0");
  } else {
    udpSend("MODE:MANUAL");
    if (leftPct == 0 && rightPct == 0) {
      udpSend("RUN:0");
    } else {
      udpSend("RUN:1");
      udpSend("LR:" + leftPct + "," + rightPct);
    }
  }
}

void execStop() {
  running    = false;
  spdPct     = 0;
  spdKnobY   = SPD_BOTTOM;
  leftPct    = 0;  rightPct    = 0;
  leftKnobY  = LR_CENTER; rightKnobY = LR_CENTER;
  udpSend("STOP");
}

void switchMode(boolean toAuto) {
  execStop();
  autoMode = toAuto;
  udpSend(toAuto ? "MODE:AUTO" : "MODE:MANUAL");
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

// ============================================================
//  ユーティリティ
// ============================================================
boolean overRect(int mx, int my, int cx, int cy, int bw, int bh) {
  return mx > cx - bw / 2 && mx < cx + bw / 2 &&
         my > cy - bh / 2 && my < cy + bh / 2;
}

color speedColor(int pct) {
  if (pct == 0)  return color(100);
  if (pct  > 0)  return color(50, 200, 100);
  return color(200, 70, 50);
}

String dirLabel(int pct) {
  if (pct > 0) return "前進";
  if (pct < 0) return "後退";
  return "停止";
}
