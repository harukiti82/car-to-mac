// サーボ単体テスト（WiFi なし）
// D9=左, D10=右  2秒回転 → 2秒停止 を繰り返す
#include <Servo.h>

Servo L, R;

void setup() {
  Serial.begin(115200);
  L.attach(9);
  R.attach(10);
  Serial.println("Servo test start");
}

void loop() {
  Serial.println("RUN  L=1700 R=1300");
  L.writeMicroseconds(1700);
  R.writeMicroseconds(1300);
  delay(2000);

  Serial.println("STOP L=1500 R=1500");
  L.writeMicroseconds(1500);
  R.writeMicroseconds(1500);
  delay(2000);
}
