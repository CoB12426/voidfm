# かんたん版リリース構成（Docker + APK + 3ステップ）

## 3ステップ導線（ユーザー向け）
1. GitHub Releases から APK をダウンロードして Android にインストール
2. PCで easy起動スクリプトを実行（Dockerでhost起動）
3. アプリ設定で host の IP と port=8000 を入力して ON AIR

### 起動コマンド
- Linux: `./scripts/easy_up.sh`
- Windows (PowerShell): `powershell -ExecutionPolicy Bypass -File .\scripts\easy_up.ps1`

### 全部まとめて起動（host + fish-speech + ollama）
- Linux: `./scripts/easy_up_all.sh`
- Windows (PowerShell): `powershell -ExecutionPolicy Bypass -File .\scripts\easy_up_all.ps1`

停止:
- Linux: `./scripts/easy_down_all.sh`
- Windows (PowerShell): `powershell -ExecutionPolicy Bypass -File .\scripts\easy_down_all.ps1`

`fish-speech/` が無い場合、`easy_up_all` は初回に自動 clone を試みます（git 必須）。

`tts.mode = "http"` の場合、easyスクリプトは `fish-speech` の server プロファイルも自動起動します。

通常の `easy_up` は Ollama を自動起動しません（到達性チェックのみ）。
`easy_up_all` は Ollama も含めて起動します。

### 停止コマンド
- Linux: `./scripts/easy_down.sh`
- Windows (PowerShell): `powershell -ExecutionPolicy Bypass -File .\scripts\easy_down.ps1`

## リリース担当者向け

### APK を作る（GitHub Actions）
- Actions → `Build Android APK` → `Run workflow`
- 成果物 `voidfm-release-apk` をダウンロード
- Releases に `voidfm-android-release.apk` として添付

### host の配布
- ユーザーはこのリポジトリを clone
- `models/` に必要ファイルを配置
- Linux: `./scripts/easy_up.sh`
- Windows: `powershell -ExecutionPolicy Bypass -File .\scripts\easy_up.ps1`

## 必要ファイル（models/）
※ `mydj-host/config.toml` の `tts.mode = "subprocess"` の場合のみ必要
- `s2`（実行可能ファイル）
- `s2-pro-q4_k_m.gguf`
- `tokenizer.json`

Windowsで手軽に試す場合は、`tts.mode = "http"` を推奨（ローカルs2不要）。

## 注意
- Fish Audio関連素材は非商用用途を前提（商用は別途契約）
- `fish-speech/` ディレクトリが存在しない場合、httpモードのTTS先は手動で用意してください
