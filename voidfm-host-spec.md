# MyDJ Host — 仕様書 & CLAUDE.md

## プロジェクト概要

スマホで音楽をストリーミング再生中、曲と曲の間にDJのトークを自動挿入するシステムのサーバーサイド。
Androidクライアントから楽曲情報を受け取り、LLMでDJトークを生成、TTSで音声合成して返す。

---

## 技術スタック

| コンポーネント | 採用技術 |
|---|---|
| Webフレームワーク | FastAPI + uvicorn |
| LLM | Ollama (HTTP API経由) |
| TTS | fish-speech-s2-pro (HTTP API経由) |
| 設定管理 | TOML (`config.toml`) |
| Python | 3.11以上 |

---

## ディレクトリ構成

```
mydj-host/
├── CLAUDE.md               # このファイル
├── main.py                 # FastAPIアプリ エントリポイント
├── routers/
│   ├── __init__.py
│   ├── health.py           # GET /ping
│   ├── config_router.py    # GET /config
│   └── talk.py             # POST /talk
├── services/
│   ├── __init__.py
│   ├── llm_client.py       # Ollamaラッパー
│   ├── tts_client.py       # fish-speech-s2-proラッパー
│   └── prompt_builder.py   # DJトーク用プロンプト構築
├── models/
│   ├── __init__.py
│   └── schemas.py          # Pydanticスキーマ定義
├── config.py               # config.toml 読み込み・バリデーション
├── config.toml             # ユーザー設定ファイル（要作成）
├── config.toml.example     # サンプル設定（リポジトリに含める）
└── requirements.txt
```

---

## 設定ファイル (`config.toml`)

```toml
[server]
port = 8000
host = "0.0.0.0"

[llm]
ollama_url = "http://localhost:11434"
default_model = "llama3.2"

[tts]
fish_speech_url = "http://localhost:8080"
default_speaker = "default"

[dj]
default_language = "ja"
default_talk_length = "medium"   # short / medium / long
```

`config.toml` が存在しない場合は起動時にエラーを出し、`config.toml.example` をコピーするよう案内すること。

---

## APIエンドポイント仕様

### `GET /ping`

死活確認。クライアントが接続テストに使う。

**レスポンス (200)**
```json
{
  "status": "ok",
  "version": "1.0"
}
```

---

### `GET /config`

クライアントがUI構築に使う情報を返す。
Ollamaに `GET /api/tags` を投げてモデル一覧を動的取得すること。

**レスポンス (200)**
```json
{
  "llm_models": ["llama3.2", "gemma3:4b", "qwen2.5:7b"],
  "default_llm": "llama3.2",
  "tts_speakers": ["default"],
  "default_speaker": "default",
  "server_version": "1.0"
}
```

Ollamaへの接続に失敗した場合は `llm_models` に `config.toml` の `default_model` のみを入れて返す（エラーにしない）。

---

### `POST /talk`

メインエンドポイント。楽曲情報を受け取り、DJトーク音声を返す。

**リクエストボディ**
```json
{
  "current_track": {
    "title": "曲名",
    "artist": "アーティスト名",
    "album": "アルバム名"
  },
  "next_track": {
    "title": "曲名",
    "artist": "アーティスト名",
    "album": "アルバム名"
  },
  "preferences": {
    "llm_model": "llama3.2",
    "language": "ja",
    "talk_length": "short"
  }
}
```

- `next_track` は省略可（曲間ではなく曲の開始時に呼ばれる場合を想定）
- `preferences` は省略可。省略時は `config.toml` のデフォルト値を使う

**レスポンス (200)**
- `Content-Type: audio/wav`
- ボディ: WAVバイナリ（16kHz, mono, 16bit）

**エラーレスポンス**
```json
{ "detail": "エラーメッセージ" }
```
- 500: LLM生成失敗 / TTS生成失敗

---

## 処理フロー (`POST /talk` 内部)

1. リクエストをバリデーション（Pydantic）
2. `preferences` とデフォルト設定をマージ
3. `prompt_builder.py` でLLM用プロンプトを構築
4. `llm_client.py` でOllamaにリクエスト → テキスト取得
5. `tts_client.py` でfish-speechにリクエスト → WAVバイナリ取得
6. WAVバイナリを `StreamingResponse` で返す

各ステップは `async/await` で実装すること。

---

## プロンプト設計 (`prompt_builder.py`)

### トーク長の目安

| `talk_length` | 文字数目安 |
|---|---|
| `short` | 30〜50文字 |
| `medium` | 80〜120文字 |
| `long` | 150〜200文字 |

### プロンプトテンプレート（日本語の例）

```
あなたはラジオDJです。次のように自然な日本語で短くトークしてください。
余計な説明や前置きは不要です。トーク本文だけを出力してください。

直前の曲: {current_artist} の「{current_title}」
{next_track_line}

{length_instruction}
```

`next_track_line` は `next_track` がある場合のみ「次の曲は {next_artist} の「{next_title}」です。」を挿入。

---

## `llm_client.py` の仕様

- Ollama の `/api/generate` エンドポイントを使う（非ストリーミング: `"stream": false`）
- タイムアウト: 30秒
- `httpx.AsyncClient` を使うこと（`requests` は使わない）

---

## `tts_client.py` の仕様

- fish-speech-s2-pro の HTTP APIを叩く
- エンドポイントやパラメータは fish-speech の公式ドキュメントに準拠
- レスポンスがWAVバイナリでない場合は例外を投げる
- タイムアウト: 60秒（TTS生成は重い）

---

## エラーハンドリング方針

- すべての外部通信（Ollama, fish-speech）は `try/except` で囲み、失敗時は `HTTPException(status_code=500)` を投げる
- 起動時に `config.toml` の存在確認・必須キーの検証を行い、不備があれば即座に終了してメッセージを表示

---

## 起動方法（README相当）

```bash
# 依存インストール
pip install -r requirements.txt

# 設定ファイル作成
cp config.toml.example config.toml
# config.toml を編集

# 起動
uvicorn main:app --host 0.0.0.0 --port 8000
```

---

## 実装時の注意

- `async/await` を全体で徹底すること
- `httpx.AsyncClient` はリクエストごとに生成せず、アプリ起動時に生成してDI（FastAPIのlifespanイベント推奨）
- 型ヒントを全関数につけること
- `print` デバッグではなく `logging` モジュールを使うこと
