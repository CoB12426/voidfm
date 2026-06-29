# voidfm

ローカルの音楽再生に AI DJ トークを差し込む実験的アプリです。

Android アプリ（`mydj_client`）と Ubuntu ホスト（`mydj-host`）の2つで動作します。

```
Android（音楽再生 + DJ トーク再生）
    ↕ HTTP
Ubuntu ホスト（LLM でトーク生成 + TTS で音声合成）
```

---

## ライセンス重要事項（TTS モデル）

Fish Audio 由来のモデル・素材は **Research / Non-Commercial 用途のみ無償利用可能**です。  
**商用利用には Fish Audio との別途ライセンス契約が必要**です。  
詳細は [Fish Audio License](https://github.com/fishaudio/fish-speech/blob/main/LICENSE) を必ず確認してください。

---
### Step:1

GitHub Releases ページから `voidfm-android-release.apk` をダウンロードしてインストール。

### ステップ:2（Ubuntu 側セットアップ）

```bash
git clone https://github.com/CoB12426/voidfm.git
cd voidfm

# Python 仮想環境
python3 -m venv voidfm
source voidfm/bin/activate

# host 設定ファイルを作成
cp mydj-host/config.toml.example mydj-host/config.toml

# 依存インストール
pip install -r mydj-host/requirements.txt
```

### ステップ:3（LLM API と TTS モデルの配置）

LLM は OpenAI 互換 API を指定できます。

```toml
[llm]
provider = "openai_compatible"
base_url = "https://api.openai.com/v1"
api_key = "env:OPENAI_API_KEY"
default_model = "auto"  # /v1/models の現在モデルを使う。固定したい場合のみ具体名を指定
```

Ollama を使う場合は以下のように変更します。

```toml
[llm]
provider = "ollama"
ollama_url = "http://localhost:11434"
default_model = "llama3.2:1b"
```

TTS は `tts.mode = "s2_server"` が推奨です。ホスト起動中に `s2.cpp` を常駐させ、リクエストごとの TTS エンジン起動を避けます。

以下をダウンロードして配置してください。

- `s2` バイナリ（`s2.cpp` をビルドして作成）
    - https://github.com/rodrigomatta/s2.cpp
- `s2-pro-q4_k_m.gguf`
    - https://huggingface.co/rodrigomt/s2-pro-gguf/resolve/main/s2-pro-q4_k_m.gguf
- `tokenizer.json`
    - https://github.com/rodrigomatta/s2.cpp/blob/main/tokenizer.json

`mydj-host/config.toml` の `s2_binary / s2_model / s2_tokenizer` を各自の配置パスに合わせて編集してください。

### ステップ:4（起動）

```bash
# hostのみ起動（バックグラウンド）
./scripts/dev_up.sh

# Flutter アプリも続けて起動する場合
./scripts/dev_up.sh --client
```

### ステップ:5（Android 側接続）

Android アプリを開き、設定画面で Ubuntu の IP アドレスとポート `8000` を入力して ON AIR。

Tailscale の利用をおすすめします。

### 停止

```bash
./scripts/dev_down.sh
```

---

## 補足

- Fish Audio 由来モデルの利用条件（非商用等）は必ず確認してください。
