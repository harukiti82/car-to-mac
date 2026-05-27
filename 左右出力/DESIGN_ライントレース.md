# ライントレース実装設計書（Sonnet 実装用）

このドキュメントは、既存の手動操縦コード `line_car_realtim2/line_car_realtim2.ino`（左右独立2サーボ、UDP受信）を起点に、**ESP32-S3 CAM を「目」として使うライントレースカー**を実装するための仕様書です。

実装は Claude Sonnet が行う前提で、リテラル解釈で破綻しない粒度（完全な関数シグネチャ、具体的なピン番号、具体的な閾値）で書いています。「適切に」「いい感じに」のような曖昧表現は使いません。

---

## 0. Sonnet が最初に Read すべきファイル

実装着手前に必ず以下を Read してください。順番もこの通り。

1. `outputs/左右出力/DESIGN_ライントレース.md`（本ファイル）
2. `outputs/左右出力/line_car_realtim2/line_car_realtim2.ino`（書き換え対象、既存の2サーボ版UDPコード）
3. `outputs/line_car_uno_r4.ino`（参考。4サーボ版だが、Serial1受信パーサと PD 制御部分の実装パターンが完成形）
4. `outputs/SETUP_配線とセットアップ.md`（ハードウェア配線・全体構成の前提）

---

## 1. システム全体構成

```
 [Mac / Processing] ───UDP(SPD/RUN/STOP/MODE)──┐
                                                ▼
 [ESP32-S3 CAM] ── Serial(UART) "L:<-100..100>\n" ──> [Arduino UNO R4 WiFi]
   ↑ OV2640                                              │
   QQVGA grayscale → 二値化 → 重心 → 誤差送信           │ 1500±OFFSET us
                                                         ▼
                                                  [FS90R-W サーボ L/R]
```

役割分担：

| デバイス | 責務 |
|----------|------|
| ESP32-S3 CAM | 画像取得 → ROI 切り出し → 二値化 → 黒ピクセル重心算出 → 中心とのずれを `-100..100` に正規化 → UART で連続送信 |
| UNO R4 WiFi | Serial1 で誤差受信、UDP で MODE/SPD/RUN を受信、PD 制御で L_SPEED/R_SPEED を算出してサーボに出力、通信タイムアウト時は安全停止 |
| Mac (Processing) | ベース速度・走行 ON/OFF・モード切替（AUTO=ライントレース / MANUAL=手動LR操作）の指示のみ |

---

## 2. ハードウェア配線

### 2.1 サーボ（既存 `line_car_realtim2.ino` を踏襲、変更なし）

| サーボ | UNO R4 ピン | 備考 |
|--------|-------------|------|
| L_SERVO | D14 (A0) | 信号線。`L_SERVO.attach(14, 1000, 2000)` のまま |
| R_SERVO | D15 (A1) | 信号線。`R_SERVO.attach(15, 1000, 2000)` のまま |

サーボ電源は別電源（4.8〜6V）から取り、UNO の GND と必ず共通化する。

### 2.2 ESP32-S3 CAM ⇔ UNO R4 (UART)

| ESP32-S3 CAM | UNO R4 | 備考 |
|--------------|--------|------|
| GPIO 43 (TX) | D0 (Serial1 RX) | ESP32 → UNO の一方向のみ使用 |
| GND | GND | 共通GND **必須** |

UNO R4 の TX (5V) → ESP32 RX への配線は**不要**（誤差は ESP32 → UNO の片方向のみ）。

ESP32-S3 CAM のボードによって UART1 のデフォルトピンは違うので、**ESP32 側コード内で `Serial1.begin(115200, SERIAL_8N1, 44, 43)` のように明示的にピンを指定**する（44=RX 未使用、43=TX）。

### 2.3 カメラピン（Freenove ESP32-S3 WROVER CAM 前提）

下記ピン定義は **Freenove ESP32-S3 WROVER CAM Board** (OV2640 搭載) のもの。
**別のボード（Seeed XIAO ESP32-S3 Sense / AI-Thinker ESP32-CAM 等）を使う場合は、ボード名でピン定義を検索し、実装時に置き換えること**。Sonnet は実装着手前にユーザーに使用ボード名を確認してよい。

```c
#define PWDN_GPIO_NUM   -1
#define RESET_GPIO_NUM  -1
#define XCLK_GPIO_NUM   15
#define SIOD_GPIO_NUM    4
#define SIOC_GPIO_NUM    5
#define Y9_GPIO_NUM     16
#define Y8_GPIO_NUM     17
#define Y7_GPIO_NUM     18
#define Y6_GPIO_NUM     12
#define Y5_GPIO_NUM     10
#define Y4_GPIO_NUM      8
#define Y3_GPIO_NUM      9
#define Y2_GPIO_NUM     11
#define VSYNC_GPIO_NUM   6
#define HREF_GPIO_NUM    7
#define PCLK_GPIO_NUM   13
```

---

## 3. 通信プロトコル

### 3.1 ESP32-S3 CAM → UNO R4（UART, 115200 bps, 8N1）

| 形式 | 意味 | 送信頻度 |
|------|------|---------|
| `L:<-100..100>\n` | ライン誤差。負=ラインが画像中央より左、正=右、0=中央 | 1フレームごと（約 30Hz 目安） |
| `L:NA\n` | ラインを検出できなかったフレーム | 検出失敗時のみ |

- 数値は整数 `-100` 〜 `+100`。文字列終端は `\n`（LF のみ、CR は不要）。
- バッファ攻撃防止のため、UNO 側パーサは 32 バイト超のラインをドロップする。
- 連続送信のスループットを抑えるため、**ESP32 側は最低 33ms 間隔で送信**（max 30Hz）。

### 3.2 Mac (Processing) → UNO R4（UDP, port 8888）

既存プロトコルを拡張：

| 形式 | 意味 |
|------|------|
| `MODE:AUTO` | ライントレースモード。ESP32 からの誤差を採用 |
| `MODE:MANUAL` | 手動モード。`LR:<left>,<right>` を採用、ESP32 の誤差は無視 |
| `SPD:<0..100>` | AUTO モード時のベース速度。デフォルト 0 |
| `LR:<left>,<right>` | MANUAL モード時の左右パーセント (-100..100)、既存仕様維持 |
| `RUN:1` / `RUN:0` | 走行 ON / OFF |
| `STOP` | 即停止 |

- 起動時のデフォルトは `MODE:MANUAL`, `running=false`, `baseSpeed=0`。これにより**起動直後に勝手に走り出さない**。
- UNO は受信時に `ACK mode=<AUTO|MANUAL> spd=<n> L=<n> R=<n> run=<0|1>` を返す。

---

## 4. UNO R4 側コード仕様（書き換え後の `line_car_realtim2.ino`）

### 4.1 グローバル変数（既存からの差分）

```c
// ---------- モード ----------
enum DriveMode { MODE_MANUAL, MODE_AUTO };
DriveMode mode = MODE_MANUAL;

// ---------- AUTO モード用 ----------
int  baseSpeed = 0;      // 0..100 (%)。AUTO時のベース速度
int  lineError = 0;      // -100..100、ESP32 から受信
bool lineValid = false;  // 直近の L: が NA でないか
float Kp = 0.6f;         // 比例ゲイン（実機で 0.4〜1.0 を試す）
float Kd = 0.2f;         // 微分ゲイン（揺れが大きいなら下げる）
int  prevError = 0;

// ---------- ライン消失タイムアウト ----------
unsigned long lastLineMs = 0;
const unsigned long LINE_TIMEOUT = 500; // ms

// ---------- Serial1 受信バッファ ----------
String s1buf = "";
```

既存の `leftPct`, `rightPct`, `running`, `L_SPEED`, `R_SPEED`, `MAX_OFFSET`, `lastCmdMs`, `CMD_TIMEOUT` は維持。

### 4.2 `setup()` への追加

```c
Serial1.begin(115200);  // ESP32-S3 CAM 受信用
```

既存の `L_SERVO.attach(14, ...)` / `R_SERVO.attach(15, ...)` / `connectWiFi()` / `Udp.begin(...)` は変更なし。

### 4.3 `loop()` のロジック

```
loop():
  receiveUDP();       // 既存の拡張版（MODE/SPD を追加パース）
  receiveSerial1();   // 新規。"L:<n>\n" / "L:NA\n" を読み取る

  if (millis() - lastCmdMs > CMD_TIMEOUT) running = false;

  if (!running) {
    L_SPEED = 0; R_SPEED = 0;
  } else if (mode == MODE_AUTO) {
    // AUTO: ベース速度 + PD 補正
    if (!lineValid || millis() - lastLineMs > LINE_TIMEOUT) {
      // ライン消失 → 停止（安全側）
      L_SPEED = 0; R_SPEED = 0;
    } else {
      int err = lineError;
      int dErr = err - prevError;
      float steer = Kp * err + Kd * dErr;        // 右に寄った（err>0）→ 右遅く
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

  L_SERVO.writeMicroseconds(1500 + L_SPEED);
  R_SERVO.writeMicroseconds(1500 - R_SPEED);   // 既存どおり R は鏡対称で符号反転
```

### 4.4 関数シグネチャ（新規／変更）

```c
void receiveUDP();          // 既存。MODE/SPD のパース追加
void receiveSerial1();      // 新規
void connectWiFi();         // 既存（変更なし）
```

`receiveSerial1()` の実装パターンは `outputs/line_car_uno_r4.ino:165-179` の `receiveSerial()` をそのまま流用してよい（ただし `L:NA` のハンドリングを追加）。`L:NA` を受信したら `lineValid = false`、数値を受信したら `lineValid = true; lastLineMs = millis();` をセット。

### 4.5 既存コードから消すもの

- なし。既存の `LR:` / `RUN:` / `STOP` パースはそのまま残す（MANUAL モードで使う）。

---

## 5. ESP32-S3 CAM 側コード仕様（新規）

ファイル: `outputs/左右出力/esp32s3_cam_linetrace/esp32s3_cam_linetrace.ino`

### 5.1 必要ライブラリ

- `esp_camera.h`（Arduino-ESP32 v2.x 以降に同梱）
- `HardwareSerial`（標準）

Arduino IDE のボードマネージャで **"esp32" by Espressif Systems (v2.0.14 以降推奨)** をインストール。ボード選択は使用機材に応じて（例: "ESP32S3 Dev Module" または "Freenove ESP32S3 WROOM"）。

### 5.2 カメラ設定（リテラル指定）

```c
camera_config_t config;
config.ledc_channel = LEDC_CHANNEL_0;
config.ledc_timer   = LEDC_TIMER_0;
config.pin_d0 = Y2_GPIO_NUM;
config.pin_d1 = Y3_GPIO_NUM;
// ... (Y4〜Y9, XCLK, PCLK, VSYNC, HREF, SIOD, SIOC, PWDN, RESET) ...
config.xclk_freq_hz = 20000000;       // 20MHz
config.pixel_format = PIXFORMAT_GRAYSCALE;  // 二値化したいのでグレースケール
config.frame_size   = FRAMESIZE_QQVGA;      // 160x120（処理軽量）
config.jpeg_quality = 12;             // GRAYSCALE 時は無視されるがセットしておく
config.fb_count     = 1;
config.fb_location  = CAMERA_FB_IN_PSRAM;   // PSRAM 必須前提
config.grab_mode    = CAMERA_GRAB_LATEST;   // 最新フレーム優先
```

`esp_camera_init(&config)` の戻り値が `ESP_OK` でなければ `Serial.printf` でエラーを出して `while(1) delay(1000);` で停止（暴走させない）。

### 5.3 ライン検出アルゴリズム（重心法）

QQVGA = 160 × 120 を前提に：

```
const int IMG_W = 160;
const int IMG_H = 120;
const int ROI_Y_TOP    = 90;     // 下から30行を ROI に
const int ROI_Y_BOTTOM = 119;
const int BIN_THRESHOLD = 80;    // 0..255、暗い側を黒ライン扱い（白背景・黒テープ前提）
const int MIN_BLACK_PIXELS = 30; // これ未満ならライン検出失敗（NA）
```

各フレームで：

1. `esp_camera_fb_get()` でフレーム取得（`fb->buf` は `IMG_W * IMG_H` バイトのグレースケール）
2. ROI = `y in [ROI_Y_TOP, ROI_Y_BOTTOM]` の全画素を走査
3. 画素値 `<= BIN_THRESHOLD` を黒（ライン）と判定し、`x` 座標の総和 `sumX` と個数 `count` を集計
4. `count < MIN_BLACK_PIXELS` ならライン未検出 → `Serial1.println("L:NA")`
5. それ以外は `centerX = sumX / count`、誤差 `err = map(centerX, 0, IMG_W - 1, -100, 100)` を計算して `Serial1.printf("L:%d\n", err)` で送信
6. `esp_camera_fb_return(fb)` を必ず呼ぶ

**白ライン on 黒床の場合は `<=` を `>=` に反転、または `BIN_THRESHOLD` を白側に設定**。デフォルトは黒ライン on 白床。

### 5.4 送信レート制御

```c
const uint32_t SEND_INTERVAL_MS = 33; // ≒30Hz
static uint32_t lastSend = 0;
if (millis() - lastSend < SEND_INTERVAL_MS) {
  esp_camera_fb_return(fb);
  return;
}
lastSend = millis();
```

### 5.5 UART 初期化

```c
Serial.begin(115200);                              // USB デバッグ
Serial1.begin(115200, SERIAL_8N1, 44, 43);         // RX=44(未使用), TX=43 → UNO R4 D0 へ
```

### 5.6 デバッグ出力

USB 側 `Serial` には、誤差値・ROI 内黒ピクセル数・FPS を**1秒ごとに**1行だけ出力（毎フレーム出すと処理を圧迫するため）。例：

```
[12.3 fps] black=842 centerX=78 err=-3
```

### 5.7 関数シグネチャ

```c
void setup();
void loop();
bool initCamera();                              // false なら停止
int  detectLineError(camera_fb_t* fb, bool& ok); // ok=false ならライン未検出
void sendError(int err, bool ok);
```

ファイル分割は不要（1つの .ino にまとめて可）。

---

## 6. 受け入れ条件（Definition of Done）

実装完了の判定は以下を **すべて** 満たすこと。

### 6.1 ビルド・配線

- [ ] `line_car_realtim2/line_car_realtim2.ino` が Arduino IDE で UNO R4 WiFi 向けに**警告なくコンパイル**できる
- [ ] `esp32s3_cam_linetrace/esp32s3_cam_linetrace.ino` が ESP32-S3 ボード向けに**警告なくコンパイル**できる
- [ ] ESP32 起動時に USB シリアル（115200）に `Camera init OK` と出る
- [ ] UNO 起動時に USB シリアル（115200）に `Connected! IP = ...` と `UDP listening on port 8888` が出る

### 6.2 通信

- [ ] ESP32 → UNO の Serial1 配線後、UNO のシリアルログに 1 秒間に 20 回以上 `lineError=...` の更新が見える
- [ ] UDP `MODE:AUTO` を送ると ACK に `mode=AUTO` が返る
- [ ] UDP `STOP` を送ると即座にサーボが 1500us（停止）に戻る
- [ ] ESP32 を物理的に外す（または電源を切る）と 500ms 以内に AUTO モードでも停止する

### 6.3 走行動作

- [ ] 車体を浮かせて `MODE:AUTO`, `SPD:50`, `RUN:1` を送ると、カメラの正面に黒テープを左右に振るだけで左右車輪の速度比が変わる（左に振ったら右車輪が速くなる、または逆）
- [ ] 実コースで `Kp=0.6, Kp+Kd調整` の範囲内で 1m 以上の直線追従ができる
- [ ] ライン消失時（カメラから黒テープを完全に外す）に 500ms 以内に停止する
- [ ] `MODE:MANUAL` に切り替えた直後、`LR:80,60` で既存の手動操縦が動く（既存挙動の非破壊）

### 6.4 安全性

- [ ] UDP コマンドが 2 秒来ないと停止する（既存 `CMD_TIMEOUT` の維持）
- [ ] 起動直後は `running=false`（誤発進しない）
- [ ] パケットバッファオーバーフロー耐性: 32 バイト超の壊れた Serial1 入力で異常動作しない

---

## 7. 実装順序（Sonnet 向け推奨）

以下の順で進めると、各段階で個別に動作確認ができる。

1. **UNO 側の `MODE:` / `SPD:` UDP パース追加**（Serial1 はまだ無視）
   - 受け入れ: UDP ACK に `mode=` `spd=` が反映される
2. **UNO 側の `receiveSerial1()` 追加**（PD は未実装、受信したら Serial に echo するだけ）
   - 受け入れ: USB→ESP32 模擬入力で `L:50\n` を送ったら `lineError=50` がログに出る
3. **UNO 側の PD 制御 + AUTO/MANUAL 分岐実装**
   - 受け入れ: 模擬入力 + UDP `MODE:AUTO, SPD:50, RUN:1` で L_SPEED/R_SPEED の値がログに変動する
4. **ESP32 側のカメラ初期化のみ**（送信なし）
   - 受け入れ: USB シリアルに `Camera init OK` と FPS が出る
5. **ESP32 側の重心算出 + Serial1 送信**
   - 受け入れ: UNO 側のログで誤差受信が連続して観測できる
6. **実コースで Kp / Kd / BIN_THRESHOLD を実機調整**

---

## 8. パラメータ調整ガイド（実機調整時の指針）

| 症状 | いじる箇所 |
|------|-----------|
| ライン追従が**逆に**曲がる | UNO 側 PD の `steer` の符号を反転、または ESP32 側の `err` の符号を反転（どちらか一方だけ） |
| 直線でフラフラ蛇行する | `Kp` を 0.1 ずつ下げる |
| カーブで反応が遅い | `Kp` を上げる、`Kd` を 0.1 ずつ上げる |
| ライン誤検出が多い（背景が暗い） | `BIN_THRESHOLD` を 60 程度に下げる、または ROI 行数を狭める |
| FPS が 10 未満まで落ちる | `frame_size` を `FRAMESIZE_QQVGA` 以下に、`fb_count=1`, `grab_mode=CAMERA_GRAB_LATEST` を確認 |
| 停止時にジワジワ動く | サーボ本体のトリマで停止位置を調整（既存 `line_car_realtim2.ino` の `1500us` は変えない） |

---

## 9. ファイル構成（実装後の到達点）

```
outputs/左右出力/
├── DESIGN_ライントレース.md                          ← 本ファイル
├── line_car_realtim2/
│   └── line_car_realtim2.ino                         ← Sonnet が書き換え
└── esp32s3_cam_linetrace/
    └── esp32s3_cam_linetrace.ino                     ← Sonnet が新規作成
```
