# voidfm

ローカルの音楽再生に AI DJ トークを差し込む実験的アプリです。

```
Android（音楽再生 + DJ トーク再生）
    ↕ HTTP
Ubuntu ホスト（LLM でトーク生成 + Chatterbox TTS で音声合成）
```

---

### ステップ 1

GitHub Releases ページから `voidfm-android-release.apk` をダウンロードしてインストール。

### ステップ 2（Ubuntu 側セットアップ）

```bash
git clone https://github.com/CoB12426/voidfm.git
cd voidfm

# Python 仮想環境
python3 -m venv voidfm
source voidfm/bin/activate

# ホスト設定ファイルを作成
cp mydj-host/config.toml.example mydj-host/config.toml

# 依存インストール
pip install -r mydj-host/requirements.txt
```

TTS のレイテンシを抑えるため、CUDA 対応 GPU を推奨します。

### ステップ 3（LLM と TTS の設定）

**LLM** — OpenAI 互換 Chat Completions API を指定できます。

```toml
[llm]
provider = "openai_compatible"
base_url = "https://api.openai.com/v1"
api_key = "env:OPENAI_API_KEY"
default_model = "auto"  # /v1/models の先頭モデルを使う。固定したい場合は具体名を指定
```

Ollama を使う場合:

```toml
[llm]
provider = "ollama"
ollama_url = "http://localhost:11434"
default_model = "llama3.2:1b"
```

**TTS** — [Chatterbox TTS](https://github.com/resemble-ai/chatterbox) はインプロセスで動作します（外部バイナリのダウンロード不要）。2 種類のモデルが使えます。

| `chatterbox_model` | 対応言語 | 備考 |
|---|---|---|
| `multilingual` | 23 言語以上（日本語含む） | 推奨 |
| `turbo` | 英語のみ | 低レイテンシ |

5〜30 秒の参照音声ファイルを指定することでボイスクローンが可能です。

```toml
[tts]
chatterbox_model = "multilingual"
language_id = "ja"
cuda_device = 0          # GPU インデックス（-1 で CPU のみ）
exaggeration = 0.5       # 感情表現の強さ（0.0〜1.0+）
cfg_weight = 0.5         # 話者一致度（低いほど自然な話速）
default_ref_audio = "voices/default.wav"

# 複数の声を登録してアプリから選択可能にする場合:
# [tts.voices]
# nova  = "voices/nova.wav"
# atlas = "voices/atlas.wav"
```

### ステップ 4（起動）

```bash
# ホストのみ起動（バックグラウンド）
./scripts/dev_up.sh

# Flutter アプリも続けて起動する場合
./scripts/dev_up.sh --client
```

### ステップ 5（Android 側接続）

Android アプリを開き、設定画面で Ubuntu の IP アドレスとポート `8000` を入力して ON AIR。

[Tailscale](https://tailscale.com) の利用をおすすめします。

### 停止

```bash
./scripts/dev_down.sh
```

---

## Android アプリの設定項目

| 設定 | 説明 |
|---|---|
| Host / Port | mydj-host が動いている Ubuntu のアドレス |
| DJ Personality | スタンダード / ハイテンション / チル / インテリ / お笑い系 |
| Talk Length | short / medium / long |
| Talk Frequency | 1〜5 曲ごとにトークを挿入 |
| DJ Name | DJ が自己紹介に使う名前（任意） |
| Your Name | DJ があなたを呼ぶ名前（任意） |
| Weather City | 天気コンテキスト用の都市名または GPS 座標 |
| Custom Prompt | 毎回の DJ プロンプトに追加する自由入力の指示 |

---

## ライセンス重要事項

本プロジェクトは Fish Audio 由来の素材と組み合わせて使用できます。  
Fish Audio 由来の素材は **Research / Non-Commercial 用途のみ無償利用可能**です。  
**商用利用には Fish Audio との別途ライセンス契約が必要**です。  
詳細は [Fish Audio License](https://github.com/fishaudio/fish-speech/blob/main/LICENSE) を確認してください。
