# voidfm

ローカルの音楽再生に AI DJ トークを差し込む実験的アプリです。

Android アプリ（`mydj_client`）と PC ホスト（`mydj-host`）の2つで動作します。

```
Android（音楽再生 + DJ トーク再生）
    ↕ HTTP
PC ホスト（LLM でトーク生成 + TTS で音声合成）
```

---

## ライセンス重要事項（TTS モデル）

Fish Audio 由来のモデル・素材は **Research / Non-Commercial 用途のみ無償利用可能**です。  
**商用利用には Fish Audio との別途ライセンス契約が必要**です。  
詳細は [Fish Audio License](https://github.com/fishaudio/fish-speech/blob/main/LICENSE) を必ず確認してください。

---

## かんたん起動（Windows / Linux + Android）

### ステップ 1：APK を Android にインストール

GitHub Releases ページから `voidfm-android-release.apk` をダウンロードしてインストール。

### ステップ 2：PC に必要なソフトをインストール（初回のみ）

| ソフト | 入手先 | 備考 |
|--------|--------|------|
| Docker Desktop | https://www.docker.com/products/docker-desktop/ | Windows では WSL2 も必要（インストーラーが案内） |
| Git | https://git-scm.com/ | デフォルト設定で OK |

インストール後は **PC を再起動**してください。

### ステップ 3：リポジトリを取得して起動（推奨スクリプト）

**Windows（PowerShell）：**

```powershell
git clone https://github.com/CoB12426/voidfm.git
cd voidfm
powershell -ExecutionPolicy Bypass -File .\scripts\easy_up_all.ps1
```

**Linux：**

```bash
git clone https://github.com/CoB12426/voidfm.git
cd voidfm
./scripts/easy_up_all.sh
```
> **初回は Docker のビルドに 20〜30 分かかります。**

### ステップ 4：モデルをダウンロード（初回のみ）

起動後、**別のターミナル**で以下を2つ実行してください。

**① LLM モデル（Ollama）：**

```bash
docker exec -it voidfm-ollama ollama pull llama3.2:1b
```

**② TTS モデル（fish-speech）：**

```bash
cd fish-speech
pip install huggingface_hub
python -c "from huggingface_hub import snapshot_download; snapshot_download('fishaudio/fish-speech-1.5', local_dir='fish-speech/checkpoints/s2-pro')"
```

> ダウンロード後は `docker restart voidfm-fish-speech` でコンテナを再起動してください。

### ステップ 5：アプリで接続

Android アプリを開き、設定画面で PC の IP アドレスとポート `8000` を入力して ON AIR。

PC の IP アドレスの確認方法：
- **Windows**：PowerShell で `ipconfig` → 「IPv4 アドレス」
- **Linux**：ターミナルで `hostname -I`
TailScaleの利用をおすすめします。

### 停止

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\scripts\easy_down_all.ps1
```

```bash
# Linux
./scripts/easy_down_all.sh
```

---

## GPU 使用の前提条件

ステップ 3 の `easy_up_all` は **GPU 前提** です。

内部では次のコマンドを実行します。

```bash
docker compose -f docker-compose.all.yml -f docker-compose.gpu.yml up -d --build
```

前提：

- **Windows**：Docker Desktop（WSL2 バックエンド）+ NVIDIA ドライバー 470 以降
- **Linux**：[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) がインストールされていること

GPU 環境がない場合は、手動で以下を使って起動してください。

```bash
docker compose -f docker-compose.all.yml up -d --build
```

---

## 起動スクリプトの種類

| スクリプト | 起動するもの | 用途 |
|-----------|-------------|------|
| `easy_up_all` | mydj-host + fish-speech + Ollama | **推奨。全部 Docker で完結** |
| `easy_up` | mydj-host のみ | Ollama をすでに別途用意している場合 |

---

## コンポーネント構成

| コンポーネント | 役割 | ポート |
|-------------|------|-------|
| `mydj-host` | API サーバー（LLM 呼び出し・TTS 制御） | 8000 |
| `fish-speech` | TTS（音声合成）サーバー | 8080 |
| `ollama` | LLM（テキスト生成）サーバー | 11434 |

---

## 公開方針

- このリポジトリには**コードのみ**を含めます
- モデルファイル（GGUF / tokenizer / checkpoints）は各自ダウンロードして配置してください
- `mydj-host/config.toml` はローカル設定として Git 管理しません

---

## 開発者向けセットアップ

必要環境：Python 3.10+、Flutter 3.x

```bash
# 初回
cp mydj-host/config.toml.example mydj-host/config.toml
# config.toml を編集してモデルパスを設定

# 起動
./scripts/dev_up.sh               # host + client
./scripts/dev_up.sh --host-only   # host のみ
./scripts/dev_down.sh             # 停止
```

`tts.mode = "subprocess"` を使う場合のモデルファイル配置：

- `s2.cpp/build/s2`（ビルド済みバイナリ）
- `s2-pro-q4_k_m.gguf`
- `tokenizer.json`

`mydj-host/config.toml` の `tts.s2_binary`、`tts.s2_model`、`tts.s2_tokenizer` を実際のパスに合わせてください。

リリース手順の詳細は [EASY_RELEASE.md](EASY_RELEASE.md) を参照。
