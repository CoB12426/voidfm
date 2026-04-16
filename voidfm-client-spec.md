# MyDJ Client — 仕様書 & CLAUDE.md

## プロジェクト概要

音楽再生中に自動でDJトークを挿入するAndroidクライアントアプリ。
`NotificationListenerService` で楽曲情報を取得し、Tailscale経由でホストへ送信。
ホストから返ってきたTTS音声を `AudioManager` のダッキング制御付きで再生する。

---

## 技術スタック

| コンポーネント | 採用技術 |
|---|---|
| UIフレームワーク | Flutter 3.x (Dart) |
| Androidネイティブ連携 | MethodChannel / EventChannel (Kotlin) |
| HTTP通信 | `http` パッケージ |
| 音声再生 | `just_audio` パッケージ |
| 設定永続化 | `shared_preferences` パッケージ |
| 権限管理 | `permission_handler` パッケージ |
| Android minimum SDK | 26 |

---

## ディレクトリ構成

```
mydj_client/
├── CLAUDE.md                          # このファイル
├── pubspec.yaml
├── lib/
│   ├── main.dart                      # エントリポイント・DI初期化
│   ├── app.dart                       # MaterialApp・ルーティング
│   ├── screens/
│   │   ├── home_screen.dart           # メイン画面（動作状況表示）
│   │   └── settings_screen.dart      # 設定画面
│   ├── services/
│   │   ├── notification_service.dart  # MethodChannel経由で楽曲情報受信
│   │   ├── host_client.dart           # ホストへのHTTP通信
│   │   └── audio_service.dart        # 音声再生・ダッキング制御
│   ├── models/
│   │   ├── track_info.dart            # 楽曲情報モデル
│   │   ├── host_config.dart           # ホスト接続設定モデル
│   │   └── dj_preferences.dart        # DJ設定モデル
│   └── providers/
│       ├── settings_provider.dart     # 設定状態管理
│       └── dj_provider.dart           # DJトーク処理状態管理
└── android/app/src/main/
    ├── AndroidManifest.xml
    └── kotlin/com/example/mydj_client/
        ├── MainActivity.kt            # MethodChannel定義
        ├── MyNotificationListener.kt  # NotificationListenerService
        └── AudioFocusManager.kt       # AudioManager ダッキング制御
```

---

## 画面仕様

### ホーム画面 (`home_screen.dart`)

- 接続状態インジケータ（未設定 / 接続中 / 接続済み / エラー）
- 現在再生中の楽曲情報（取得できた場合）
- DJトーク処理中インジケータ
- 設定画面へのナビゲーションボタン
- サービスのON/OFFトグル

### 設定画面 (`settings_screen.dart`)

**接続設定（必須）**
- ホストアドレス入力欄（例: `100.x.x.x` または Tailscaleホスト名）
- ポート番号入力欄（デフォルト: `8000`）
- 「接続テスト」ボタン → `/ping` を叩いて結果をSnackBarで表示

**DJ設定（詳細、省略時はホストのデフォルト値を使用）**
- 使用LLMモデル（ドロップダウン、`/config` から動的取得）
- 言語選択（日本語 / English）
- トーク長（短め / 普通 / 長め）
- ダッキング音量（スライダー、0〜80%、デフォルト30%）

設定は `SharedPreferences` に保存。ホストアドレス未設定の場合はホーム画面から設定画面へ自動遷移。

---

## Androidネイティブ層 (Kotlin)

### `MyNotificationListener.kt`

`NotificationListenerService` を継承する。

**取得対象の通知フィールド**
- `MediaMetadata.METADATA_KEY_TITLE` → 曲名
- `MediaMetadata.METADATA_KEY_ARTIST` → アーティスト名
- `MediaMetadata.METADATA_KEY_ALBUM` → アルバム名

**EventChannel への送信仕様**
- チャンネル名: `com.example.mydj/notification`
- 曲が変わったタイミングで以下のMapをFlutter側へ送信:
```dart
{
  "title": "曲名",
  "artist": "アーティスト名",
  "album": "アルバム名",
  "package": "通知元のパッケージ名"
}
```
- 同じ曲の通知が連続した場合は送信しない（重複排除）

**AndroidManifest.xml に必要な設定**
```xml
<service
    android:name=".MyNotificationListener"
    android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"
    android:exported="true">
    <intent-filter>
        <action android:name="android.service.notification.NotificationListenerService" />
    </intent-filter>
</service>
```

初回起動時、通知アクセス権限が未付与であれば `NotificationListenerSettings` へ誘導するダイアログを表示すること。

---

### `AudioFocusManager.kt`

**MethodChannel仕様**
- チャンネル名: `com.example.mydj/audio_focus`
- メソッド:
  - `requestDuck` → AudioFocusを要求してダッキング開始。引数: `{"duckVolume": 0.3}`
  - `abandonFocus` → AudioFocusを解放してダッキング終了

**実装方針**
- `AudioManager.requestAudioFocus()` に `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` を使う
- ダッキング音量はFlutter側から渡された値を使う
- AudioFocusの変化は `OnAudioFocusChangeListener` で監視し、予期しない喪失時はFlutter側に通知する

---

## Flutter側の処理フロー

### 楽曲変化 → DJトーク再生までの流れ

```
1. MyNotificationListener が曲変化を検知
2. EventChannel経由で Flutter の notification_service.dart へ通知
3. dj_provider.dart が直前の曲情報と新しい曲情報をセット
4. host_client.dart が POST /talk を送信
   - 処理中は isProcessing = true（UIに反映）
5. レスポンス（WAVバイナリ）を受信
6. audio_service.dart:
   a. AudioFocusManager.requestDuck() を呼んでダッキング開始
   b. just_audio で音声再生
   c. 再生完了後に AudioFocusManager.abandonFocus() を呼んでダッキング終了
7. isProcessing = false
```

### 曲情報の保持

- `dj_provider.dart` は `previousTrack` と `currentTrack` を保持する
- 新しい通知が来たら `currentTrack → previousTrack` にシフトして更新
- `previousTrack` が null の場合（初回）は `/talk` を送信しない

---

## `host_client.dart` の仕様

```dart
class HostClient {
  Future<Uint8List> fetchTalk({
    required TrackInfo currentTrack,
    TrackInfo? nextTrack,
    required DjPreferences preferences,
  });

  Future<bool> ping();

  Future<HostConfig> fetchConfig();
}
```

- ベースURL: `http://{hostAddress}:{port}`
- タイムアウト: `ping` は5秒、`fetchTalk` は90秒
- エラー時は例外を投げる（呼び出し側でSnackBar表示などに使う）

---

## `audio_service.dart` の仕様

```dart
class AudioService {
  Future<void> playFromBytes(Uint8List wavBytes, {double duckVolume = 0.3});
  Future<void> stop();
}
```

- `just_audio` の `AudioPlayer` を使う
- `playFromBytes` の内部で MethodChannel経由のダッキング制御を呼ぶ（`requestDuck` → 再生 → `abandonFocus`）
- 再生中に新しいリクエストが来た場合は既存の再生を停止してから新しい音声を再生する

---

## 状態管理

`riverpod` または `provider` を使うこと（どちらでも可）。
以下の状態を管理する：

| 状態 | 説明 |
|---|---|
| `connectionStatus` | 未設定 / 接続済み / エラー |
| `isServiceEnabled` | サービスON/OFF |
| `isProcessing` | /talk リクエスト処理中フラグ |
| `currentTrack` | 現在再生中の曲情報 |
| `previousTrack` | 直前の曲情報 |
| `lastTalkText` | 最後に生成されたトーク（デバッグ用、UIに表示してもよい） |

---

## 実装時の注意

- `NotificationListenerService` の権限チェックは `NotificationManagerCompat.getEnabledListenerPackages()` で行う
- Flutter側でのEventChannel受信はアプリがバックグラウンドでも動作する必要があるため、Serviceとして常駐させること
- `just_audio` のAudioPlayerは singleton で管理し、dispose漏れに注意
- ホストアドレスが未設定の状態で `/talk` を呼ばないようにガードを入れること
- `http` パッケージでバイナリを受け取る場合は `response.bodyBytes` を使う

---

## `pubspec.yaml` に追加するパッケージ

```yaml
dependencies:
  flutter:
    sdk: flutter
  http: ^1.2.0
  just_audio: ^0.9.40
  shared_preferences: ^2.2.0
  permission_handler: ^11.3.0
  provider: ^6.1.0        # または riverpod

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
```

---

## 起動・開発手順

```bash
# 依存取得
flutter pub get

# Androidエミュレータまたは実機で起動
flutter run

# ビルド
flutter build apk --release
```

初回起動時のチェックリスト：
1. 通知アクセス権限を付与（設定 → 通知へのアクセス）
2. 設定画面でホストアドレスを入力
3. 接続テストが成功することを確認
4. 音楽アプリで曲を再生し、曲変化を検知できるか確認
