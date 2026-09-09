# Avo — how to use

**Launch:** `/Applications/Avo.app` (menu bar icon). First launch opens onboarding: grant permissions, connect Google, pick a voice (optional).

**Talk:** hold your configured talk key (default **fn**), speak, then let go. Right ⌘ / ⌥ / ⌃ arm after a brief solitary hold so normal keyboard shortcuts remain untouched. Silent modifier taps cancel quietly and never send a request; tap fn/F5/F6 (no speech) to open the text composer. Control+Option works as an alias. Esc cancels.

**Screen context:** hold your talk key, speak, release. Avo captures the screen after the hold and sends automatically. The capture briefly becomes a floating card that flies into the notch. Settings → General → Context has separate **Screen awareness** and **Screenshot animation** toggles; animation off still captures normally. Reduce Motion uses a brief stationary capture cue.

**Selected text:** text you highlight before speaking or opening the composer is included automatically. Clipboard text and unselected window text are never added as context. You can still deliberately paste text or attach files.

**Point at things:** with screen awareness enabled, move the cursor while holding your talk key to mark a region. Avo sends that marked screenshot instead of adding a second unmarked screen image.

**Confirm:** anything that sends, creates, changes, or runs shows a card. Enter or click Confirm; Esc cancels; or hold fn and say "yes" / "no" / "make it 7:30".

**Think hard:** say "think hard about …" or toggle Deep in Settings → General. Runs your model at max effort.

**Voice replies:** off by default. Settings → Voice → Speak replies. The engine is Apple's on-device voice, which needs no key; Gemini is optional and needs a Gemini key. Preview either before choosing.

**Voice mode (conversation):** menu bar → Voice Mode, or say "start voice mode". Uses the OpenAI Realtime API — interruptible, same tools, so it needs an OpenAI key. Ends on "that's all" / 25 s silence / toggle.

**Coding agents:** "have Claude fix the flaky test in my-project" / "run Codex on the notes project to …". Progress in the side of the notch; permission questions arrive as cards you answer by voice or click. "Stop it" stops the open task.

**Memory:** "remember that …" writes to `~/Library/Application Support/Avo/AVO_MEMORY.md`. "Forget …" removes. The file is loaded into every turn.

**Type instead:** menu bar → Type to Avo (⌘T), or `open "avo://ask?text=…"` from a script or Shortcut.

**Permissions:** see the Permissions section below.

**Cost:** whatever your provider charges. Usage depends on requests, images, tools and spoken replies. `~/Library/Application Support/Avo/avo.log` reports uncached input, cache reads, cache writes, and output/reasoning tokens per turn, plus a cost estimate from your model's published rates. The estimate excludes built-in web search fees, Realtime, and Gemini speech. With a local server (Ollama, LM Studio) there is nothing to pay.

**Your model:** Settings → General → Model. Pick the provider style (OpenAI Responses, or OpenAI-compatible chat completions), the base URL, the key and the model id. Anything OpenAI-compatible works — Ollama, LM Studio, OpenRouter, Groq, xAI, Anthropic's compatibility endpoint. **Detect local** probes for an Ollama server already running on this Mac; it never starts one.

**Keys are configurable** in Settings → General → Keys: hold-to-talk (fn, right ⌘, right ⌥, right ⌃, ⌃⌥, F5, F6) and the composer shortcut (⌥ Space default). Clicking the notch also opens the composer.

**Dictation quality** is configurable in Settings → Voice → Dictation. Avo uses Apple's on-device short-dictation model with punctuation. Pick the far-microphone or speech-variation profile when appropriate, and add names or technical terms to Custom vocabulary.

**fn key note:** in System Settings → Keyboard, set "Press 🌐 key to" = **Do Nothing**, so a plain fn hold does not also open Emoji or Dictation.

## More you can do
- **Send later**: "send Sam 'running late' at 9 tomorrow" → scheduled action card; fires on its own, result pops in the notch. "What's scheduled?" lists reminders, scheduled sends, watches, monitors.
- **Reply watches**: after Avo sends a text or email it watches that thread and pops "Sam replied: …" once.
- **Email monitors**: "tell me when Stripe emails me" → Gmail watch, checked every 2 min, notifies once per new match.
- **Side notch**: a slim tab on the right screen edge. Slides out for running coding tasks, finished results, and your recent exchanges (click one to reopen it). Toggle in the menu bar menu.
- **Hands-free**: Settings → Voice → Hands-free. Say "Hey Avo, …" with no keys. A small dot sits on the notch while it listens.
- **Apple Notes**: list, search, read, create, append.
- **Custom MCP servers**: put servers in `~/Library/Application Support/Avo/mcp.json` (`{"servers": {"name": {"command": "npx", "args": ["-y", "some-mcp"]}}}` or `"url"` for HTTP). Their tools appear as `mcp_<server>_<tool>` and get confirmation cards for anything that sends/creates/deletes.
- **Composer**: click the notch or ⌥ Space. Paste text or images, drop files, or use the paperclip. Highlighted text and the screen you were on come along.

## Permissions

Avo asks for four permissions up front, during onboarding, and everything else only when a tool
actually needs it. Every one of them is visible with live status in **Settings → Permissions**, where
**Request** shows the system prompt (when macOS offers one) and **Open Settings** jumps to the right
pane of System Settings.

**Asked up front (onboarding, step 3):**
- **Microphone** — hears you while you hold the talk key. Required to continue.
- **Speech Recognition** — turns your speech into text, on this Mac. Required to continue.
- **Input Monitoring** — detects the talk key while another app is in front. Can be granted later.
- **Accessibility** — reads selected text and the app you are in. Can be granted later.

Onboarding will not move past step 3 until Microphone and Speech Recognition are granted; the other
two can wait, and Avo asks again the first time it needs them.

**Asked when a tool first needs one:**
- **Screen Recording** — screen awareness and "what's on my screen".
- **Full Disk Access** — iMessage history, and Desktop/Documents searches without per-folder prompts.
  macOS offers no in-app prompt for this one: open System Settings and add Avo to the list.
- **Reminders** — creating and reading reminders.
- **Calendars** — reading Apple Calendar events.
- **Location** — "where am I" and nearby searches.
- **Automation** — controlling Messages, Spotify and other apps by Apple Events.

When one of these is missing, the tool that needed it shows a card explaining what is missing rather
than failing silently. Nothing is requested at launch, so a fresh install reaches the notch and the
onboarding window immediately.

## Settings

Open with the menu bar item, **⌘,**, or `open "avo://settings"`. Eight pages.

**General**
- *Hold to talk* — which key arms listening: fn, right ⌘, right ⌥, right ⌃, ⌃⌥, F5 or F6.
- *Open composer* — global shortcut for the typing composer, or Off.
- *Screen awareness* — whether Avo may capture your screen at all.
- *Always attach the screen* — capture on every request instead of only when the request refers to it.
- *Screenshot animation* — the capture flies into the notch; off captures silently.
- *Ask before actions* — show an editable card before anything is sent, created or deleted.
- *Sounds* — the soft cues for listening, cards and completion.
- *Your name* — what Avo calls you.
- *Writing style* — the rules applied whenever Avo drafts a message, email or reply.
- *Context files* — files read whole into every request; add with the picker, remove per row.
- *Provider style* — OpenAI (Responses API) or OpenAI-compatible (chat completions).
- *Base URL* — the API root. Anything OpenAI-compatible works.
- *API key* — the brain provider's key, stored in the Keychain, with a Test button.
- *Model* — any model id the server accepts.
- *Detect local* — read-only probe for an Ollama server already running on this Mac. It never starts one.
- *Effort* — reasoning budget for everyday requests: None, Low, Medium, High, Max.
- *Deep mode* — slower and more thorough; uses the deep effort below.
- *Deep effort* — the budget deep mode uses.
- *Default reminder list* — a picker over your Reminders lists once access exists, a text field before that. Empty, the default, uses the list Reminders itself defaults to.
- *Launch at login* — start Avo quietly in the menu bar when you sign in.
- *Keep screenshots for* — keep forever, or 7 / 14 / 30 / 90 days. Default: keep forever. A limit
  you pick is applied at launch; nothing is deleted until you pick one.
- *Purge screenshots now* — deletes the ones already past that age.
- *Keep history for* — same choices for turns and summaries. Default: keep forever.
- *Clear history* — deletes every turn and summary, after one confirmation.

**Voice**
- *Microphone* — Avo's own input device. Does not change where music or replies play.
- *Recognition profile* — Standard, far from microphone, or accent/speech variation.
- *Custom vocabulary* — comma-separated names and technical terms recognition should favour.
- *Speak replies* — read the one-line reply aloud after each request.
- *Engine* — Apple (on-device, no key) or Gemini.
- *TTS model* — which Gemini speech model, when Gemini is the engine.
- *Voice* — the Gemini prebuilt voice, with a Preview button on both engines.
- *Style* — how the Gemini voice should sound; prepended to every line.
- *Realtime model* — the model voice mode uses.
- *Start voice mode* — begins a hands-open conversation. Also in the menu bar.
- *Listen for a wake word* — on-device hands-free listening (macOS 26 and later).
- *Wake word* — the phrase; "Hey Avo", "OK Avo" and "Avo" always work.
- *Status* — what the wake-word listener is doing right now.

**Apps**
- *MCP servers* — the list from `~/Library/Application Support/Avo/mcp.json`, each with its transport,
  tool count or startup error, an on/off switch and Remove.
- *Add server…* — a form for a name plus either a stdio command and arguments, or an HTTP URL and headers.
- *Restart servers* — re-reads the file, restarts every server and swaps in its tools.
- One card per tool group (iMessage, Reminders, Finder, Gmail, Calendar, Coding, MCP servers, …): a
  switch that hides the whole group from the model, and a disclosure listing each tool and whether it
  asks first.

**Google**
- *Account* — Connect (browser sign-in) or Disconnect. Only a refresh token is kept, in the Keychain.
- *OAuth client* — pick the credentials JSON downloaded from the Google Cloud console.
- *Scopes* — what sign-in will request, read-only.

**Coding**
- *Default agent* — Claude Code or Codex, used when you do not name one.
- *Auto-approve* — skip permission prompts inside the coding agent.
- *Detected CLIs* — where `claude` and `codex` were found in your login shell's PATH, read-only.

**Keys** — Gemini, Fish Audio and xAI keys, each with show/hide and a Test button. The brain's own key
lives in General → Model. Everything here is stored in the macOS Keychain.

**Permissions** — the ten rows described above, with live status.

**About**
- Version and the macOS this is running on.
- *Memory* — Open or Reveal `AVO_MEMORY.md`.
- *Log* — Open `avo.log`.
- *History* — open the History window (search, per-day grouping, summaries, Clear).
- *Reset onboarding* — runs the first-run flow again, now.
- *Redact spoken text* — on by default. The log quotes your requests (`Turn start:`, transcripts,
  wake-word utterances); with this on, those quotations are replaced with `[redacted]` in the copy
  that goes into the zip.
- *Export diagnostics* — writes `~/Desktop/Avo-diagnostics-<date>.zip` containing your log and a
  settings dump. No API keys and no tokens: secrets are listed as present or absent only. macOS asks
  for Desktop access the first time.
