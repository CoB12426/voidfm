# VoidFM (mydj_client + mydj-host)

ローカル音楽再生に DJ トークを差し込む実験プロジェクトです。

## 0) ライセンス重要事項（TTSモデル）
- Fish Audio由来のモデル/素材（以下 Fish Audio Materials）は、
  **Research / Non-Commercial 用途のみ無償利用可能**です。
- **商用利用には Fish Audio との別途ライセンス契約が必要**です。
- 再配布・公開時は、Fish Audioライセンスの配布条件（ライセンス同梱、
  指定アトリビューション等）を満たしてください。
- 詳細は[[fish-speech/LICENSE](fish-speech/LICENSE)](https://github.com/fishaudio/fish-speech/blob/main/LICENSE) を必ず確認してください。

## 1) 公開方針
- このリポジトリには **コードのみ** を含めます。
- モデル（GGUF / tokenizer / checkpoints）は各自ダウンロードして配置してください。
- `mydj-host/config.toml` はローカル設定として Git 管理しません。

## 2) 必要要件
- Linux
- Python 3.10+
- Flutter 3.x
- （任意）Ollama または互換 LLM API

## 3) クイックスタート

### 初回
1. Python 仮想環境を作成（`/voidfm`）
2. `mydj-host/config.toml.example` を `mydj-host/config.toml` にコピー
3. モデルファイルを配置して `config.toml` のパスを更新

### 起動（1コマンド）
- 全体起動（host + client）
  - `./scripts/dev_up.sh`
- host のみ起動
  - `./scripts/dev_up.sh --host-only`
- host 停止
  - `./scripts/dev_down.sh`

## 4) モデル配置ルール（例）
- `s2-pro-q4_k_m.gguf`
- `tokenizer.json`
- `s2.cpp/build/s2`（実行バイナリ）

`mydj-host/config.toml` の以下を実体パスに合わせてください。
- `tts.s2_binary`
- `tts.s2_model`
- `tts.s2_tokenizer`

## 5) Reddit公開時の注意
- モデル本体は再配布しない
- ライセンス表記をREADMEと投稿文に明記
- 動作動画（30〜60秒）を先頭に置く

## 6) Fish Audio利用時の最低対応
- リポジトリに [NOTICE](NOTICE) を含める
- Fish Audioライセンス本文を確認可能にする（本リポジトリでは [fish-speech/LICENSE](fish-speech/LICENSE)）
- 商用利用の可能性がある場合は事前に Fish Audio へ連絡する

詳細チェックは [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) を参照。
