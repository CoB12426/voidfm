# リリース手順

このドキュメントはリリース担当者向けです。  
ユーザー向けのセットアップ手順は [README.md](README.md) を参照してください。

---

## APK のビルド（Android）

1. GitHub Actions → `Build Android APK` → `Run workflow` を実行
2. 成果物 `voidfm-release-apk` をダウンロード
3. GitHub Releases に `voidfm-android-release.apk` として添付

---

## スクリプトの動作詳細

### `easy_up_all`（全部 Docker）

`docker-compose.all.yml` を使って以下を一括起動します：

| コンテナ | イメージ/ビルド元 |
|---------|----------------|
| `voidfm-ollama` | `ollama/ollama:latest` |
| `voidfm-fish-speech` | `fish-speech/` ディレクトリからビルド |
| `voidfm-host` | `mydj-host/` ディレクトリからビルド |

自動処理：
- `fish-speech/` が存在しない場合、自動で `git clone`（git が必要）
- `config.toml` が存在しない場合、`config.allinone.toml.example` からコピー

### `easy_up`（host のみ）

`docker-compose.easy.yml` で `voidfm-host` のみを起動します。

自動処理：
- `config.toml` が存在しない場合、`config.docker.toml.example` からコピー
- `tts.mode = "http"` の場合、fish-speech サーバーも合わせて起動
- `tts.mode = "subprocess"` の場合、`models/` の必要ファイルを確認してから起動
- Ollama の到達性チェック（起動はしない）

---

## `tts.mode = "subprocess"` に必要なファイル（`models/`）

Linux 環境で subprocess モードを使う場合のみ必要です。  
Windows や `easy_up_all` では不要です。

- `s2`（Linux 実行可能ファイル）
- `s2-pro-q4_k_m.gguf`
- `tokenizer.json`

---

## 注意事項

- Fish Audio 関連素材は非商用用途のみ無償（商用利用は別途契約が必要）
- `fish-speech/` が存在しない状態で `easy_up`（`http` モード）を使う場合は、TTS サーバーを手動で用意してください
