# Changelog

## Unreleased

- Voice mode is a real conversation in the notch: live captions, mute and end controls, the last turns stay on screen, Esc ends the session, and hold-to-talk no longer fights the microphone.
- The model can put tables, JSON trees, highlighted code, markdown documents and small charts on screen (`present_table`, `present_json`, `present_code`, `present_markdown`, `present_chart`). Reply bubbles render GFM tables and coloured code.
- Notch motion: card and chip enter/exit, phase changes, and status pulses use the same springs as the rest of the glass.

## 1.0.0 — 2026-09-09

First public release. Formerly Halo.

- Hold-to-talk voice agent in the notch. Dictation and wake-word detection run on-device.
- Bring your own model: OpenAI, or any OpenAI-compatible server (Ollama, LM Studio, OpenRouter,
  Groq, xAI, Anthropic's compatibility endpoint).
- Tools for Messages, Reminders, Notes, Finder, Spotify, Gmail, Google Calendar and Google Drive,
  plus Claude Code and Codex. Anything that sends, creates or deletes something shows an editable
  card first.
- Custom MCP servers from `mcp.json`, with an editor in Settings → Apps.
- Voice mode, scheduled actions, reply watches, email monitors, and a side notch for long tasks.
