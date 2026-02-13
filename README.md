# Chris Dictation

A lightweight macOS menubar app for voice dictation. Hold a hotkey, speak, release — your speech is transcribed via OpenAI and pasted into the focused text field (or copied to clipboard).

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange)

## Features

- **Hold-to-dictate**: Hold fn (configurable), speak, release to transcribe and paste
- **Fast**: Uses `gpt-4o-mini-transcribe` by default for near-instant results
- **Smart insertion**: Pastes directly into focused text fields, falls back to clipboard with visual feedback
- **Floating overlay**: Animated waveform shows recording state, processing animation while transcribing
- **Voice corrections dictionary**: Custom word/phrase replacements applied after transcription
- **Transcript log**: Searchable markdown log organized by day
- **Cost tracking**: Per-transcription cost estimates in history

## Install

Requires macOS 13+ and the Swift toolchain (included with Xcode or Xcode Command Line Tools).

```bash
git clone https://github.com/cjsauer/chris-dictation.git
cd chris-dictation
scripts/install_app.sh
open ~/Applications/Chris\ Dictation.app
```

## Setup

1. **API Key**: Create `~/.config/chris-dictation/config.json`:
   ```json
   {
     "model": "gpt-4o-mini-transcribe",
     "apiKey": "your-openai-api-key"
   }
   ```
   Or set the `OPENAI_API_KEY` environment variable.

2. **Microphone**: Allow when macOS prompts on first recording.

3. **Accessibility**: System Settings → Privacy & Security → Accessibility → add the app. Required for paste simulation and hotkey monitoring.

## Config

All config lives in `~/.config/chris-dictation/config.json`:

| Key | Default | Description |
|-----|---------|-------------|
| `apiKey` | `null` | OpenAI API key (or use `OPENAI_API_KEY` env var) |
| `model` | `gpt-4o-mini-transcribe` | OpenAI transcription model |
| `dictionaryPath` | `~/.config/chris-dictation/voice-corrections.json` | Path to corrections dictionary |
| `maxHistoryItems` | `20` | Max transcriptions kept in history |
| `hotkey` | `fn` | Hotkey to hold for dictation (`fn` or `rightOption`) |

## Voice Corrections

Create a JSON dictionary to fix recurring mistranscriptions:

```json
{
  "misheard word": "correct word",
  "Acme Corp": "ACME Corp"
}
```

Words are used both as a Whisper prompt hint and as post-transcription replacements.

## Files

| Path | Description |
|------|-------------|
| `~/.config/chris-dictation/config.json` | App configuration |
| `~/.config/chris-dictation/voice-corrections.json` | Default corrections dictionary |
| `~/.config/chris-dictation/history.json` | Transcription history with costs |
| `~/.config/chris-dictation/transcript-log.md` | Searchable transcript log by day |

## License

MIT
