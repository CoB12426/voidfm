# On-Device モードのモデル準備

Settings → DJ ENGINE で **On-Device** を選ぶと、PCなしでスマホ単体でDJトークを生成します。台本は LiteRT-LM 上の Gemma 4 E2B IT、音声は sherpa-onnx 上の Supertonic 3 で生成します（英語のみ）。

## 1. Gemma 4 E2B（台本生成）

1. [litert-community/gemma-4-E2B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/tree/main) から `gemma-4-E2B-it.litertlm` を端末に保存します（約2.6 GB）。
2. Settings → **Select Gemma 4 E2B model** で選択します。アプリ専用領域にコピーされるため、コピー分の空き容量も必要です。

旧MediaPipe用の `.bin`、GGUF、PyTorch重み、任意の `.tflite` は使えません。GPUでの起動を試し、使えない端末ではCPUに切り替えます。

## 2. Supertonic 3（音声合成）

1. [sherpa-onnx の Supertonic 3 INT8 モデル](https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2)（`.tar.bz2`）を端末に保存します。
2. Settings → **Select Supertonic 3 archive** で選択します。必要な7ファイルがアプリ内に展開されます。個別の `.onnx` だけを選んでも動作しません。

10種類の声（F1〜F5、M1〜M5）から選んで試聴でき、Speech Pace で話速を調整できます（初期値 0.85 倍）。Supertonic 3 はインラインの演技タグに対応しないため、台本中の `[laugh]` などのタグは合成前に取り除かれます。モデルのライセンスは [OpenRAIL-M](https://huggingface.co/Supertone/supertonic-3) です。

## 補足

- 両方のモデルが揃うと ON AIR を有効にできます。ON AIR 時にモデルを読み込むため、最初のイントロ再生まで少し時間がかかります。
- 生成はすべて端末内で行います。ネットワークを使うのは初回のフォント取得だけです。
- 実機での推論速度・メモリ使用量は端末によって大きく異なります。
