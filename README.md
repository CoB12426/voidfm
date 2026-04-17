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

### ステップ:2

```bash
git clone https://github.com/CoB12426/voidfm.git
cd voidfm
./scripts/easy_up_all.sh
```

### ステップ:3

```bash
docker exec -it voidfm-ollama ollama pull llama3.2:1b
```

### ステップ:4

Android アプリを開き、設定画面で Ubuntu の IP アドレスとポート `8000` を入力して ON AIR。

TailScale の利用をおすすめします。

### 停止

```bash
./scripts/easy_down_all.sh
```

---

## GPU USAGE

- NVIDIA ドライバー **560 以降**（CUDA 12.6 対応）
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) がインストールされていること

GPU がない場合は手動で CPU モード起動：

```bash
docker compose -f docker-compose.all.yml up -d --build
```
