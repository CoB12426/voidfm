# Reddit r/SideProject 投稿テンプレ（日本語下書き）

## タイトル案（英語推奨）
I built VoidFM: an auto DJ commentary app that injects AI talk between songs

## 本文テンプレ（英語化して投稿推奨）
Hi everyone, I built **VoidFM**, a side project that adds short AI DJ commentary between tracks during music playback.

### Why I made this
I wanted a lightweight "radio-like" layer over personal playlists without manual editing.

### What it does
- Detects track changes
- Generates short DJ talk
- Plays TTS between songs
- Lets users configure host/model/language/talk length

### Tech stack
- Flutter (Android client)
- FastAPI (host server)
- Local TTS via s2.cpp + GGUF model
- Optional local LLM endpoint

### Important note
Model files are **not** included in the repo.
Users download and place GGUF/tokenizer files locally.

Fish Audio-related model/material usage is for research/non-commercial by default;
commercial usage requires a separate license from Fish Audio.

### GitHub
<YOUR_GITHUB_URL>

I’d love feedback on UX, reliability, and open-source structure.
