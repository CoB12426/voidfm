# voidfm

An experimental app that inserts AI DJ talk into local music playback. \
There are bugs/glitches exist. \
Tested only on Google Pixel 9 for client and RTX3060 12GB for host (local llm with llama.cpp and TTS generation)


https://github.com/user-attachments/assets/b3248831-3243-49ec-8531-66829b471580


The Android app generates DJ talk in one of two ways, selectable in **Settings → DJ ENGINE**:

| Mode | Where talk is generated | Needs |
|---|---|---|
| **Remote** | Ubuntu PC: any LLM + Chatterbox TTS | The `voidfm-host` package running on a PC reachable from the phone |
| **On-Device** | The phone itself: Gemma 4 E2B (LiteRT-LM) + Supertonic 3 | Two model files on the phone; English only |

```
Android app (music playback + DJ talk playback)
   ├─ Remote    ── HTTP ──> Ubuntu PC (LLM talk generation + Chatterbox TTS)
   └─ On-Device ─────────> Gemma 4 E2B + Supertonic 3 on the phone
```

---

## Android app

Download the APK from the GitHub Releases page and install it.

1. Allow **Notification access** for VoidFM in Android settings (used to follow the music player).
2. Open **Settings** and pick a DJ engine:
   - **Remote** — enter the address and port printed by `voidfm start` (see below), then tap **Connect**.
   - **On-Device** — select the Gemma 4 E2B and Supertonic 3 model files. See [docs/ON_DEVICE_MODELS.md](docs/ON_DEVICE_MODELS.md).
3. Play music in your player app and switch **ON AIR**.

## PC host (Ubuntu 22.04 / 24.04)

Download `voidfm-host_<version>_all.deb` from the GitHub Releases page, then:

```bash
sudo apt install ./voidfm-host_*_all.deb
voidfm start
```

The first `voidfm start` (run as your normal user, not root):

1. creates a Python environment in `~/.local/share/voidfm` and installs PyTorch / Chatterbox TTS (several GB),
2. asks which LLM to use — **Ollama on this PC** (installed for you if missing), an **OpenAI-compatible server** you already run (llama.cpp, LM Studio, …) or the **OpenAI API**,
3. starts the host as a systemd user service and prints the address to enter in the app.

A CUDA-capable NVIDIA GPU is recommended for reasonable TTS latency. Using [Tailscale](https://tailscale.com) is recommended for connecting from outside your home network.

| Command | |
|---|---|
| `voidfm start` / `stop` / `restart` | Start, stop, or restart the host |
| `voidfm status` | Show whether it is running and the address to connect to |
| `voidfm logs -f` | Follow the log (first start downloads the TTS model) |
| `voidfm enable` / `disable` | Start automatically at login |
| `voidfm configure` | Re-run the setup wizard |
| `voidfm config` | Edit `~/.config/voidfm/config.toml` (voice cloning, multiple voices, …) |
| `voidfm uninstall` | Remove the Python environment (then `sudo apt remove voidfm-host`) |

### Panel icon

The package also installs a panel icon (**VoidFM Host** in the app grid, `voidfm tray` from a terminal). It starts automatically at login from the next login on; open it from the app grid to use it right after installing. From its menu you can start / stop / restart the host, see the address to enter in the app, open the setup wizard or the config file, follow the log, and turn autostart on or off. On Ubuntu's default GNOME desktop the icon appears in the top bar through the preinstalled AppIndicator extension.

API keys can be put in `~/.config/voidfm/env` (e.g. `OPENAI_API_KEY=...`) and referenced from the config as `api_key = "env:OPENAI_API_KEY"`.

---

## Development

```
app/        Flutter Android app (both DJ engines)
host/       Python host (FastAPI + LLM client + Chatterbox TTS)
  bin/voidfm  host launcher CLI (installed as /usr/bin/voidfm)
  bin/voidfm-tray  panel icon (GTK AppIndicator, installed as /usr/bin/voidfm-tray)
packaging/  .deb build script and systemd unit
docs/       notes
```

```bash
# Host from a checkout (uses the same ~/.config/voidfm and ~/.local/share/voidfm)
host/bin/voidfm start
python3 -m unittest discover -s host/tests

# Build the .deb into dist/
packaging/ubuntu/build-deb.sh

# App
cd app && flutter test && flutter run
```

## Android App Settings

| Setting | Description |
|---|---|
| DJ Engine | Remote or On-Device |
| Host / Port | Address of the PC running `voidfm` (Remote mode) |
| On-Device Model / DJ Voice / Speech Pace | Model files, Supertonic 3 voice and speed (On-Device mode) |
| DJ Personality | standard / energetic / chill / intellectual / comedian |
| Talk Length | short / medium / long |
| Talk Frequency | Every 1–5 songs |
| DJ Name | Optional name the DJ uses to introduce themselves |
| Your Name | Optional listener name the DJ calls you by |
| Custom Prompt | Extra instructions appended to every DJ prompt |
