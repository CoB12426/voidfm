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

## かんたん起動（Ubuntu + Android）

### ステップ 1：APK を Android にインストール

GitHub Releases ページから `voidfm-android-release.apk` をダウンロードしてインストール。

### ステップ 2：Ubuntu に必要なソフトをインストール（初回のみ）

```bash
# Docker
sudo apt install docker.io docker-compose-v2
sudo usermod -aG docker $USER  # 再ログインで反映

# ビルドツール（s2.cpp のビルドに必要）
sudo apt install git cmake build-essential
```

インストール後は **再ログイン**してください。

### ステップ 3：リポジトリを取得して起動

```bash
git clone https://github.com/CoB12426/voidfm.git
cd voidfm
./scripts/easy_up_all.sh
```

> **初回は s2.cpp のビルドと Docker のビルドに 10〜20 分かかります。**

### ステップ 4：モデルをダウンロード（初回のみ）

起動後、**別のターミナル**で以下を実行してください。

**① LLM モデル（Ollama）：**

```bash
docker exec -it voidfm-ollama ollama pull llama3.2:1b
```

**② TTS モデル（GGUF）：**

`easy_up_all` 実行時に自動ダウンロードされます。  
手動でダウンロードする場合：

```bash
mkdir -p models
curl -L -o models/s2-pro-q4_k_m.gguf \
  "https://huggingface.co/rodrigomt/s2-pro-gguf/resolve/main/s2-pro-q4_k_m.gguf?download=true"
```

### ステップ 5：アプリで接続

Android アプリを開き、設定画面で Ubuntu の IP アドレスとポート `8000` を入力して ON AIR。

```bash
# IP アドレスの確認
hostname -I
```

TailScale の利用をおすすめします。

### 停止

```bash
./scripts/easy_down_all.sh
```

---

## GPU 使用の前提条件

`easy_up_all` は **GPU 前提** で起動します（GPU がなければ自動で CPU モードにフォールバック）。

前提：

- NVIDIA ドライバー **560 以降**（CUDA 12.6 対応）
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) がインストールされていること

```bash
# ドライバー確認
nvidia-smi

# ドライバーが古い場合
ubuntu-drivers devices
sudo apt install nvidia-driver-580  # 表示されたバージョンに合わせて

# NVIDIA Container Toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

GPU がない場合は手動で CPU モード起動：

```bash
docker compose -f docker-compose.all.yml up -d --build
```

---

## コンポーネント構成

| コンポーネント | 役割 | ポート |
|-------------|------|-------|
| `mydj-host` | API サーバー（LLM 呼び出し・TTS 制御） | 8000 |
| `ollama` | LLM（テキスト生成）サーバー | 11434 |

TTS（音声合成）は `models/s2`（s2.cpp GGUF バイナリ）を subprocess で呼び出します。

---

## 公開方針

- このリポジトリには**コードのみ**を含めます
- モデルファイル（GGUF）は初回起動時に自動ダウンロードされます
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

`mydj-host/config.toml` の `tts.s2_binary`、`tts.s2_model`、`tts.s2_tokenizer` を実際のパスに合わせてください。

リリース手順の詳細は [EASY_RELEASE.md](EASY_RELEASE.md) を参照。
