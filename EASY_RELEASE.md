# かんたん版リリース構成（Docker + APK + 3ステップ）

## 3ステップ導線（ユーザー向け）
1. GitHub Releases から APK をダウンロードして Android にインストール
2. PCで `./scripts/easy_up.sh` を実行（Dockerでhost起動）
3. アプリ設定で host の IP と port=8000 を入力して ON AIR

## リリース担当者向け

### APK を作る（GitHub Actions）
- Actions → `Build Android APK` → `Run workflow`
- 成果物 `voidfm-release-apk` をダウンロード
- Releases に `voidfm-android-release.apk` として添付

### host の配布
- ユーザーはこのリポジトリを clone
- `models/` に必要ファイルを配置
- `./scripts/easy_up.sh`

## 必要ファイル（models/）
- `s2`（実行可能ファイル）
- `s2-pro-q4_k_m.gguf`
- `tokenizer.json`

## 注意
- Fish Audio関連素材は非商用用途を前提（商用は別途契約）
