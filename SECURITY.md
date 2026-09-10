# Security

Avo runs on your Mac, with the permissions you grant, and talks to the model provider you configure.
It has no backend of its own.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

Email the maintainer through GitHub (Stu1124) or open a [private vulnerability advisory](https://github.com/Stu1124/avo/security/advisories/new) on this repository. Include:

- What a stranger, another app on the same Mac, or a malicious MCP server can do
- Steps to reproduce
- The Avo version (`Settings → About`) and macOS version

You should hear back within a few days. Please give us a chance to ship a fix before you publish.

## What Avo can do

Avo is not sandboxed. With the permissions you grant, tools can read Messages, mail, calendars,
files, the screen, and more, and they can send, create, or delete things. Acting tools show an
editable confirmation card first (Settings → General → **Ask before actions**, on by default).
A few small local actions do not: rewriting selected text, pasting at the cursor, opening a file,
Spotify playback, and dispatching Claude Code or Codex (those agents ask before they do anything
destructive).

## What is trusted

- **The model.** It chooses tools and fills their arguments. Treat a provider you do not run
  yourself as untrusted input that still has to pass the confirmation card.
- **`avo://`.** Any app or script on this Mac can open `avo://ask?text=…`, which starts a real
  turn. `avo://compose`, `avo://settings`, `avo://voice`, `avo://quit` and `avo://restart` are
  likewise local. Do not install Avo on a Mac you share with people you would not let type in
  your notch.
- **MCP servers.** A server in `~/Library/Application Support/Avo/mcp.json` is a program Avo
  starts, or an HTTP endpoint it calls, with whatever headers you stored. Writing tools from a
  server still go through a confirmation card. Only add servers you would run yourself.
- **Coding agents.** Claude Code and Codex run as local CLIs with the rights those tools have.
  Avo does not sandbox them further. Settings → Coding → **Auto-approve** skips their in-agent
  permission prompts.

## What leaves the Mac

Dictation and the wake word run on-device. Hold-to-talk does not upload audio. Voice mode
sends microphone audio to OpenAI for the length of that session.

A request sends the transcript, recent conversation, tool results the model needs, and a
screenshot when the request is about the screen, to the provider in Settings → General → Model.
Point that at Ollama or LM Studio and nothing leaves the machine.

Keys live in the macOS Keychain under `app.avo.mac`. **Settings → About → Export diagnostics**
writes a zip of the log and a settings dump; secrets are listed as present or absent, never
included. Spoken text and tool arguments are redacted from that log copy by default.

## Google

Gmail, Google Calendar and Drive use an OAuth client **you** create. Avo stores the client id,
secret, and refresh token in the Keychain. Revoke access at
[myaccount.google.com](https://myaccount.google.com) → Security → Third-party access.
