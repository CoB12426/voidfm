# リリース手順

このドキュメントはリリース担当者向けです。  
ユーザー向けのセットアップ手順は [README.md](README.md) を参照してください。

---

## APK のビルド（Android）

1. GitHub Actions → `Build Android APK` → `Run workflow` を実行
2. 成果物 `voidfm-release-apk` をダウンロード
3. GitHub Releases に `voidfm-android-release.apk` として添付

---

## 配布方針（2026-04）

Docker での同梱配布は一旦中止し、以下の方式で配布する。

- ユーザーは Ubuntu 上でローカル実行環境を作成
- `mydj-host/config.toml` を各自編集
- 外部モデル（`s2` / `*.gguf` / `tokenizer.json`）は README にリンクのみ掲載
- 起動はターミナルから `./scripts/dev_up.sh --host-only`

---

## リリース時チェックリスト（ローカル実行版）

1. README の手順が現行コードと一致している
2. `mydj-host/config.toml.example` のキーが最新
3. `scripts/dev_up.sh` / `scripts/dev_down.sh` で起動・停止できる
4. Android APK で `http://<host-ip>:8000/ping` が通る
5. TTS モデルのライセンス注記（非商用等）が README に明記されている


