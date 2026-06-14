/**
 * ============================================================
 *  ラインカー シンプルコントローラー
 *  Processing → Arduino UNO R4 WiFi（UDP / APモード）
 * ============================================================
 *  キーボード操作:
 *    ↑ / ↓      速度 +5 / -5
 *    1〜9        速度を直接設定（1=10%, 2=20%, ... 9=90%）
 *    0           速度 100%
 *    スペース    即時停止（速度0）
 *
 *  送信プロトコル:
 *    速度 > 0 のとき: "LR:<speed>,<speed>" を 20Hz で送信
 *    速度 = 0 のとき: "STOP" を 20Hz で送信
 *
 *  Arduino の WiFi AP "LineCar" に Mac を接続してから起動
 * ============================================================
 */

import java.net.*;

// ---- 通信設定 ----
final String ARDUINO_IP   = "192.168.4.1";
final int    ARDUINO_PORT = 8888;

DatagramSocket udpSocket;
InetAddress    arduinoAddr;

// ---- 状態 ----
int speed = 0;  // 0〜100

// ---- ACK ----
String ackText = "---";
long   ackTime = 0;

// ---- 送信 ----
long lastSendMs = 0;
final int SEND_INTERVAL = 50;  // 20Hz
String lastSentMsg = "";

// ---- 送信ログ（直近5件）----
String[] sendLog = new String[5];
int logIndex = 0;

// ============================================================
void setup() {
  size(400, 300);
  textAlign(CENTER, CENTER);
  smooth();

  for (int i = 0; i < sendLog.length; i++) sendLog[i] = "";

  try {
    udpSocket   = new DatagramSocket();
    arduinoAddr = InetAddress.getByName(ARDUINO_IP);
    println("UDP ready -> " + ARDUINO_IP + ":" + ARDUINO_PORT);
  } catch (Exception e) {
    println("UDP error: " + e.getMessage());
  }

  // ACK 受信スレッド
  try {
    final DatagramSocket recv = new DatagramSocket(ARDUINO_PORT);
    Thread t = new Thread(new Runnable() {
      public void run() {
        byte[] buf = new byte[128];
        while (true) {
          try {
            DatagramPacket pkt = new DatagramPacket(buf, buf.length);
            recv.receive(pkt);
            ackText = new String(pkt.getData(), 0, pkt.getLength(), "UTF-8").trim();
            ackTime = System.currentTimeMillis();
          } catch (Exception e) {}
        }
      }
    });
    t.setDaemon(true);
    t.start();
  } catch (Exception e) {
    println("ACK recv failed: " + e.getMessage());
  }
}

// ============================================================
void draw() {
  background(28);

  // 送信
  if (millis() - lastSendMs > SEND_INTERVAL) {
    sendSpeed();
    lastSendMs = millis();
  }

  // ---- タイトル ----
  fill(140);
  textSize(13);
  text("Simple Controller  -  " + ARDUINO_IP, width / 2, 20);

  // ---- 速度バー ----
  int barW = 300;
  int barH = 40;
  int barX = (width - barW) / 2;
  int barY = 55;

  // 背景
  fill(50);
  noStroke();
  rect(barX, barY, barW, barH, 6);

  // 塗り
  if (speed > 0) {
    float fillW = map(speed, 0, 100, 0, barW);
    fill(50, 200, 100);
    rect(barX, barY, fillW, barH, 6);
  }

  // 速度テキスト
  fill(255);
  textSize(22);
  if (speed == 0) {
    text("STOP", width / 2, barY + barH / 2);
  } else {
    text("SPEED: " + speed + "%", width / 2, barY + barH / 2);
  }

  // ---- 送信中のコマンド ----
  fill(100);
  textSize(12);
  text("送信中: " + lastSentMsg, width / 2, barY + barH + 25);

  // ---- パルス値（Arduino側の計算値）----
  int lrUs = 1500 + (int)map(speed, 0, 100, 0, 500);
  int rlUs = 1500 - (int)map(speed, 0, 100, 0, 500);
  fill(80);
  textSize(11);
  text("L_us=" + lrUs + "  R_us=" + rlUs, width / 2, barY + barH + 45);

  // ---- ACK ----
  boolean ackAlive = (System.currentTimeMillis() - ackTime < 2000);
  fill(ackAlive ? color(60, 200, 100) : color(80));
  textSize(11);
  text("ACK: " + ackText, width / 2, barY + barH + 70);

  // ---- 送信ログ ----
  fill(60);
  textSize(10);
  textAlign(LEFT, TOP);
  int logY = 210;
  text("--- send log ---", 20, logY);
  for (int i = 0; i < sendLog.length; i++) {
    int idx = (logIndex - 1 - i + sendLog.length * 10) % sendLog.length;
    if (sendLog[idx].length() > 0) {
      text(sendLog[idx], 20, logY + 14 + i * 13);
    }
  }
  textAlign(CENTER, CENTER);

  // ---- 操作ガイド ----
  fill(70);
  textSize(10);
  text("[arrow-up/down] +/-5    [1-9] 10-90%    [0] 100%    [space] STOP", width / 2, height - 15);
}

// ============================================================
void keyPressed() {
  if (key == ' ') {
    speed = 0;
    return;
  }

  if (key >= '1' && key <= '9') {
    speed = (key - '0') * 10;
    return;
  }
  if (key == '0') {
    speed = 100;
    return;
  }

  if (key == CODED) {
    if (keyCode == UP) {
      speed = constrain(speed + 5, 0, 100);
    } else if (keyCode == DOWN) {
      speed = constrain(speed - 5, 0, 100);
    }
  }

  if (key == ESC) key = 0;
}

// ============================================================
void sendSpeed() {
  String msg;
  if (speed == 0) {
    msg = "STOP";
  } else {
    msg = "LR:" + speed + "," + speed;
  }
  udpSend(msg);
  lastSentMsg = msg;
}

void udpSend(String msg) {
  if (udpSocket == null || arduinoAddr == null) return;
  try {
    byte[] data = msg.getBytes("UTF-8");
    DatagramPacket pkt = new DatagramPacket(data, data.length, arduinoAddr, ARDUINO_PORT);
    udpSocket.send(pkt);
    sendLog[logIndex % sendLog.length] = millis() + "ms  " + msg;
    logIndex++;
  } catch (Exception e) {
    println("send error: " + e.getMessage());
  }
}
