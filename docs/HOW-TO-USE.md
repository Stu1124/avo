# How to use Avo

**Launch:** `/Applications/Avo.app` (menu bar icon). First launch opens onboarding: grant permissions, connect Google, pick a voice (optional).

**Talk:** hold your configured talk key (default **fn**), speak, then let go. Right ⌘ / ⌥ / ⌃ arm after a short hold on their own, so your normal keyboard shortcuts keep working. Tapping a modifier cancels and sends nothing; tapping fn, F5 or F6 without speaking opens the text composer. Control+Option works as an alias. Esc cancels.

**Screen context:** hold your talk key, speak, release. Avo captures the screen after the hold and sends it with the request. The capture becomes a floating card that flies into the notch. Settings → General → Context has separate **Screen awareness** and **Screenshot animation** toggles; with the animation off Avo still captures. Reduce Motion shows a short stationary cue instead.

**Selected text:** Avo attaches text you highlight before you speak or open the composer. It does not read your clipboard or the rest of the window. You can still paste text or attach files yourself.

**Point at things:** with screen awareness enabled, move the cursor while holding your talk key to mark a region. Avo sends that marked screenshot instead of adding a second unmarked screen image.

**Confirm:** anything that sends, creates, changes, or runs shows a card. Enter or click Confirm; Esc cancels; or hold fn and say "yes" / "no" / "make it 7:30".

**Think hard:** say "think hard about …" or toggle Deep in Settings → General. Runs your model at max effort.

**Voice replies:** off by default. Settings → Voice → Speak replies. The engine is Apple's on-device voice, which needs no key; Gemini is optional and needs a Gemini key. Preview either before choosing.

**Voice mode (conversation):** menu bar → Voice Mode, or say "start voice mode". It runs on the OpenAI Realtime API, so it needs an OpenAI key. You can interrupt it, and it has the same tools. It ends on "that's all", 25 s of silence, or the toggle.

**Coding agents:** "have Claude fix the flaky test in my-project" / "run Codex on the notes project to …". Progress in the side of the notch; permission questions arrive as cards you answer by voice or click. "Stop it" stops the open task.

**Memory:** "remember that …" writes to `~/Library/Application Support/Avo/AVO_MEMORY.md`. "Forget …" removes a line. Avo reads the file on every turn.

**Type instead:** menu bar → Type to Avo (⌘T), or `open "avo://ask?text=…"` from a script or Shortcut.

**Permissions:** see the Permissions section below.

**Cost:** whatever your provider charges. Usage depends on requests, images, tools and spoken replies. `~/Library/Application Support/Avo/avo.log` reports uncached input, cache reads, cache writes, and output/reasoning tokens per turn, plus a cost estimate from your model's published rates. The estimate leaves out built-in web search fees, Realtime, and Gemini speech. A local server (Ollama, LM Studio) costs nothing.

**Your model:** Settings → General → Model. Pick the provider style (OpenAI Responses, or OpenAI-compatible chat completions), the base URL, the key and the model id. Anything OpenAI-compatible works: Ollama, LM Studio, OpenRouter, Groq, xAI, Anthropic's compatibility endpoint. **Detect local** probes for an Ollama server already running on this Mac. It does not start one.

**Keys are configurable** in Settings → General → Keys: hold-to-talk (fn, right ⌘, right ⌥, right ⌃, ⌃⌥, F5, F6) and the composer shortcut (⌥ Space default). Clicking the notch also opens the composer.

**Dictation quality** is configurable in Settings → Voice → Dictation. Avo uses Apple's on-device short-dictation model with punctuation. Pick the far-microphone or speech-variation profile if one fits how you speak, and add names or technical terms to Custom vocabulary.

**fn key note:** in System Settings → Keyboard, set "Press 🌐 key to" = **Do Nothing**, so a plain fn hold does not also open Emoji or Dictation.

## More you can do
- **Send later**: "send Sam 'running late' at 9 tomorrow" opens a scheduled action card. Avo sends at that time and puts the result in the notch. "What's scheduled?" lists reminders, scheduled sends, watches and monitors.
- **Reply watches**: after Avo sends a text or email it watches that thread and shows "Sam replied: …" once.
- **Email monitors**: "tell me when Stripe emails me" sets a Gmail watch. Avo checks every 2 minutes and tells you once per new match.
- **Side notch**: a slim tab on the right screen edge. It slides out for running coding tasks, finished results, and your recent exchanges (click one to reopen it). Toggle it in the menu bar menu.
- **Hands-free**: Settings → Voice → Hands-free. Say "Hey Avo, …" with no keys. A small dot shows on the notch while it listens.
- **Apple Notes**: list, search, read, create, append.
- **Custom MCP servers**: put servers in `~/Library/Application Support/Avo/mcp.json` (`{"servers": {"name": {"command": "npx", "args": ["-y", "some-mcp"]}}}` or `"url"` for HTTP). Their tools appear as `mcp_<server>_<tool>` and get confirmation cards for anything that sends/creates/deletes.
- **Composer**: click the notch or ⌥ Space. Paste text or images, drop files, or use the paperclip. Avo also attaches your highlighted text and the screen you were on.

## Permissions

Avo asks for four permissions up front, during onboarding, and for the rest only when a tool needs
one. All ten appear with live status in **Settings → Permissions**, where **Request** opens the macOS
prompt (when macOS offers one) and **Open Settings** jumps to the right pane of System Settings.

**Asked up front (onboarding, step 3):**
- **Microphone**: hears you while you hold the talk key. Required to continue.
- **Speech Recognition**: turns your speech into text on this Mac. Required to continue.
- **Input Monitoring**: detects the talk key while another app is in front. Can be granted later.
- **Accessibility**: reads your selected text and the app you are in. Can be granted later.

Onboarding will not move past step 3 until Microphone and Speech Recognition are granted; the other
two can wait, and Avo asks again the first time it needs them.

**Asked when a tool first needs one:**
- **Screen Recording**: screen awareness and "what's on my screen".
- **Full Disk Access**: iMessage history, and Desktop/Documents searches without per-folder prompts.
  macOS offers no in-app prompt for this one: open System Settings and add Avo to the list.
- **Reminders**: creating and reading reminders.
- **Calendars**: reading Apple Calendar events.
- **Location**: "where am I" and nearby searches.
- **Automation**: controlling Messages, Spotify and other apps by Apple Events.

When one of these is missing, the tool that needed it shows a card naming it. Avo asks for nothing at
launch, so a fresh install reaches the notch and the onboarding window without a prompt.

## Settings

Open with the menu bar item, **⌘,**, or `open "avo://settings"`. Eight pages.

**General**
- *Hold to talk*: the key that arms listening. fn, right ⌘, right ⌥, right ⌃, ⌃⌥, F5 or F6.
- *Open composer*: global shortcut for the typing composer, or Off.
- *Screen awareness*: whether Avo may capture your screen.
- *Always attach the screen*: capture on every request instead of only when the request refers to it.
- *Screenshot animation*: the capture flies into the notch; off captures with no animation.
- *Ask before actions*: show an editable card before anything is sent, created or deleted.
- *Sounds*: the cues for listening, cards and completion.
- *Your name*: what Avo calls you.
- *Writing style*: the rules Avo applies when it drafts a message, email or reply.
- *Context files*: files Avo reads whole into every request; add with the picker, remove per row.
- *Provider style*: OpenAI (Responses API) or OpenAI-compatible (chat completions).
- *Base URL*: the API root. Anything OpenAI-compatible works.
- *API key*: the brain provider's key, stored in the Keychain, with a Test button.
- *Model*: any model id the server accepts.
- *Detect local*: read-only probe for an Ollama server already running on this Mac. It does not start one.
- *Effort*: reasoning budget for everyday requests. None, Low, Medium, High or Max.
- *Deep mode*: slower and more thorough; uses the deep effort below.
- *Deep effort*: the budget deep mode uses.
- *Default reminder list*: a picker over your Reminders lists once access exists, a text field before that. Empty, the default, uses the list Reminders itself defaults to.
- *Launch at login*: starts Avo in the menu bar when you sign in.
- *Keep screenshots for*: keep forever, or 7 / 14 / 30 / 90 days. Default: keep forever. Avo applies
  the limit you pick at launch, and deletes nothing until you pick one.
- *Purge screenshots now*: deletes the ones already past that age.
- *Keep history for*: same choices for turns and summaries. Default: keep forever.
- *Clear history*: deletes every turn and summary, after one confirmation.

**Voice**
- *Microphone*: Avo's own input device. It does not change where music or replies play.
- *Recognition profile*: Standard, far from microphone, or accent/speech variation.
- *Custom vocabulary*: comma-separated names and technical terms the recognizer should favour.
- *Speak replies*: read the one-line reply aloud after each request.
- *Engine*: Apple (on-device, no key) or Gemini.
- *TTS model*: which Gemini speech model, when Gemini is the engine.
- *Voice*: the Gemini prebuilt voice, with a Preview button on both engines.
- *Style*: how the Gemini voice should sound; prepended to every line.
- *Realtime model*: the model voice mode uses.
- *Start voice mode*: begins a hands-open conversation. Also in the menu bar.
- *Listen for a wake word*: on-device hands-free listening (macOS 26 and later).
- *Wake word*: the phrase. "Hey Avo", "OK Avo" and "Avo" always work.
- *Status*: what the wake-word listener is doing.

**Apps**
- *MCP servers*: the list from `~/Library/Application Support/Avo/mcp.json`, each with its transport,
  tool count or startup error, an on/off switch and Remove.
- *Add server…*: a form for a name plus either a stdio command and arguments, or an HTTP URL and headers.
- *Restart servers*: re-reads the file, restarts every server and swaps in its tools.
- One card per tool group (iMessage, Reminders, Finder, Gmail, Calendar, Coding, MCP servers, …): a
  switch that hides the whole group from the model, and a disclosure listing each tool and whether it
  asks first.

**Google**
- *Account*: Connect (browser sign-in) or Disconnect. Avo keeps one refresh token, in the Keychain.
- *OAuth client*: pick the credentials JSON downloaded from the Google Cloud console.
- *Scopes*: what sign-in will request, read-only.

**Coding**
- *Default agent*: Claude Code or Codex, used when you do not name one.
- *Auto-approve*: skip permission prompts inside the coding agent.
- *Detected CLIs*: where Avo found `claude` and `codex` in your login shell's PATH, read-only.

**Keys**: Gemini, Fish Audio and xAI keys, each with show/hide and a Test button. The brain's own key
lives in General → Model. Avo stores all of them in the macOS Keychain.

**Permissions**: the ten rows described above, with live status.

**About**
- Version and the macOS this is running on.
- *Memory*: Open or Reveal `AVO_MEMORY.md`.
- *Log*: Open `avo.log`.
- *History*: open the History window (search, per-day grouping, summaries, Clear).
- *Reset onboarding*: runs the first-run flow again, now.
- *Redact spoken text*: on by default. The log quotes your requests (`Turn start:`, transcripts,
  wake-word utterances). With this on, the copy that goes into the zip replaces those quotations with
  `[redacted]`.
- *Export diagnostics*: writes `~/Desktop/Avo-diagnostics-<date>.zip` containing your log and a
  settings dump. No API keys and no tokens: secrets are listed as present or absent only. macOS asks
  for Desktop access the first time.
