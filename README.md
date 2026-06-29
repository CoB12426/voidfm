# voidfm

An experimental app that inserts AI DJ talk into local music playback.


https://github.com/user-attachments/assets/b3248831-3243-49ec-8531-66829b471580



```
Android (music playback + DJ talk playback)
    ↕ HTTP
Ubuntu host (LLM talk generation + Chatterbox TTS synthesis)
```

---

### Step 1

Download `voidfm-android-release.apk` from the GitHub Releases page and install it on your Android device.

### Step 2 — Ubuntu Setup

```bash
git clone https://github.com/CoB12426/voidfm.git
cd voidfm

# Create Python virtual environment
python3 -m venv voidfm
source voidfm/bin/activate

# Create host config file
cp mydj-host/config.toml.example mydj-host/config.toml

# Install dependencies
pip install -r mydj-host/requirements.txt
```

A CUDA-capable GPU is recommended for reasonable TTS latency.

### Step 3 — Configure LLM and TTS

**LLM** — any OpenAI-compatible Chat Completions API:

```toml
[llm]
provider = "openai_compatible"
base_url = "https://api.openai.com/v1"
api_key = "env:OPENAI_API_KEY"
default_model = "auto"  # uses /v1/models; set a concrete name if needed
```

To use Ollama instead:

```toml
[llm]
provider = "ollama"
ollama_url = "http://localhost:11434"
default_model = "llama3.2:1b"
```

**TTS** — [Chatterbox TTS](https://github.com/resemble-ai/chatterbox) runs in-process (no external binary required). Two model variants are available:

| `chatterbox_model` | Languages | Notes |
|---|---|---|
| `multilingual` | 23+ (incl. Japanese) | Recommended |
| `turbo` | English only | Lower latency |

Voice cloning is supported by providing a 5–30 second reference audio file:

```toml
[tts]
chatterbox_model = "multilingual"
language_id = "en"
cuda_device = 0          # GPU index; -1 for CPU only
exaggeration = 0.5       # emotion strength (0.0–1.0+)
cfg_weight = 0.5         # speaker similarity (lower = more natural pacing)
default_ref_audio = "voices/default.wav"

# Optional: register multiple voices for in-app selection
# [tts.voices]
# nova  = "voices/nova.wav"
# atlas = "voices/atlas.wav"
```

### Step 4 — Start the Host

```bash
# Start host only (background)
./scripts/dev_up.sh

# Also start the Flutter app
./scripts/dev_up.sh --client
```

### Step 5 — Connect from Android

Open the Android app, enter the Ubuntu host's IP address and port `8000` in the Settings screen, then go ON AIR.

Using [Tailscale](https://tailscale.com) is recommended for easy remote connectivity.

### Stop

```bash
./scripts/dev_down.sh
```

---

## Android App Settings

| Setting | Description |
|---|---|
| Host / Port | Address of the Ubuntu host running mydj-host |
| DJ Personality | standard / energetic / chill / intellectual / comedian |
| Talk Length | short / medium / long |
| Talk Frequency | Every 1–5 songs |
| DJ Name | Optional name the DJ uses to introduce themselves |
| Your Name | Optional listener name the DJ calls you by |
| Weather City | City name or GPS coordinates for weather context |
| Custom Prompt | Extra instructions appended to every DJ prompt |

---

## License Notice

This project may be used with Fish Audio materials.  
Fish Audio materials are **free for Research / Non-Commercial use only**.  
**Commercial use requires a separate license agreement with Fish Audio.**  
See [Fish Audio License](https://github.com/fishaudio/fish-speech/blob/main/LICENSE) for details.
