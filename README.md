# voidfm

An experimental app that inserts AI DJ talk into local music playback.


https://github.com/user-attachments/assets/b3248831-3243-49ec-8531-66829b471580



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

### Step 3 — Configure LLM API and Place TTS Models

The host can use any OpenAI-compatible Chat Completions API.

```toml
[llm]
provider = "openai_compatible"
base_url = "https://api.openai.com/v1"
api_key = "env:OPENAI_API_KEY"
default_model = "auto"  # use /v1/models; set a concrete model if needed
```

To keep using Ollama, switch the LLM block to:

```toml
[llm]
provider = "ollama"
ollama_url = "http://localhost:11434"
default_model = "llama3.2:1b"
```

For TTS, `tts.mode = "s2_server"` is recommended. The host starts `s2.cpp` once and keeps it running while the host is up, instead of launching the TTS engine for every request.

Download and place the following files:

- `s2` binary (build from `s2.cpp`)
    - https://github.com/rodrigomatta/s2.cpp
- `s2-pro-q4_k_m.gguf`
    - https://huggingface.co/rodrigomt/s2-pro-gguf/resolve/main/s2-pro-q4_k_m.gguf
- `tokenizer.json`
    - https://github.com/rodrigomatta/s2.cpp/blob/main/tokenizer.json

Edit `s2_binary`, `s2_model`, and `s2_tokenizer` in `mydj-host/config.toml` to match the paths where you placed the files.

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

## License Notice (TTS Model)

Models and assets derived from Fish Audio are **free for Research / Non-Commercial use only**.  
**Commercial use requires a separate license agreement with Fish Audio.**  
Please review the [Fish Audio License](https://github.com/fishaudio/fish-speech/blob/main/LICENSE) before use.
