# Case: Final Plan

A HeyClicky-style Mac buddy that sits next to your cursor, sees your screen, listens, talks back,
and does simple tasks for you. It runs on the **Claude Code you already have**: no API keys,
no extra subscription, no big downloads.

---

## 1. What we decided

| Topic | Decision |
|---|---|
| Platform | Mac only, macOS 26+, Apple Silicon |
| App type | Native Swift app (SwiftUI + AppKit), lives in the menu bar, no Dock icon |
| Look & feel | Like HeyClicky: a small buddy next to your cursor that flies to things and talks |
| Brain | Your installed `claude` command, started once and kept running |
| Hotkey | **⌥⌘ together**: **hold** = talk (default), **tap** = type |
| Listening | Apple's built-in speech recognition, English (India) |
| Speaking | Apple's built-in voice, **Aman (Premium)** by default; Tara (Premium) available in Settings |
| Talk or text? | Talks + shows a small caption; mute button in the menu bar |
| Memory | Remembers the conversation; starts fresh after 10 min idle or "New chat". Separately, a list of facts about you, grouped by topic with related details in one row. Stated facts save straight away; things that keep coming up save after 3 different chats. You can see and delete them, and deleted things stay gone |
| Window | One window with Chats, Meetings and Memory, opened from the menu bar. makemvp's colours and Inter Tight, following the Mac's light or dark mode |
| Pointing | Real button list from macOS first (exact), screenshot guess only as backup |
| Doing tasks | A small toolbox our app owns; **always asks before sending anything** |
| Downloads | None: everything uses what's already on the Mac |
| References | Clicky and Sentient OS as references. We write our own code by default. Sentient OS is AGPL-3.0: if we reuse any of its code (only when it really helps), Case must also be released under AGPL-3.0 with credit to Sentient OS. |

---

## 2. What it looks like

**Menu bar icon (top right)**
```
✦  ← click it
┌───────────────────────────┐
│ Ask about screen     ⌥␣   │
│ Start meeting notes       │
│ New chat                  │
│ ───────────────────────── │
│ 🔊 Voice on        [mute] │
│ Brain: Claude Code ✓      │
│ Settings…                 │
│ Quit                      │
└───────────────────────────┘
```

**The buddy: always next to your cursor, small and quiet**
```
   ↖  (your cursor)
    ◆  ← buddy
```

**Hold ⌥ Space and talk: the buddy pulses and your words appear live**
```
   ↖
    ◆ ●●● "how do I invite someone here"
```

**Let go: it answers out loud and flies to the right button**
```
                               ╭─────────╮
    ◆ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ▶  │ Invite  │   ← glowing box on the real button
                               ╰─────────╯
    ┌────────────────────────────────────┐
    │ type their email, then hit invite. │   ← caption (same words it speaks)
    └────────────────────────────────────┘
```

**Tap ⌥ Space (don't hold): type instead of talking**
```
    ┌──────────────────────────────────────┐
    │ ✦  Ask anything about your screen…   │
    └──────────────────────────────────────┘
```

**Confirm card (before anything is sent)**
```
    ┌──────────────────────────────────────┐
    │ 💬 WhatsApp → Rahul                  │
    │ "I'll be 10 min late"                │
    │              [ Cancel ]  [ Send ⏎ ]  │
    └──────────────────────────────────────┘
```

**Meeting mode**
```
    ┌────────────────────────────┐
    │ 🔴 Recording  12:04 [Stop] │      ← small pill at the top of the screen
    └────────────────────────────┘

    ┌────────────────────────────────────────┐
    │ 📝 Meeting: 32 min                     │
    │ Action items:                          │
    │  ☐ Manav: send the deck by Friday      │
    │  ☐ Priya: book the venue               │
    │ [Copy] [Full transcript] [→ Notion]    │
    └────────────────────────────────────────┘
```

Esc hides the bubble, caption and highlights.

---

## 3. How each feature works (the flow)

### A. Screen help: "What is this?" / "What do I do here?"
```
Hold ⌥ Space and speak        → buddy pulses, words appear live (Apple, on your Mac)
Let go                        → app collects, in about 0.2 sec:
                                  1. screenshot of the screen under your cursor (shrunk)
                                  2. numbered list of buttons on screen: "#1 File, #7 Invite…"
                                  3. what you said
                              → sends all 3 to Claude (already running)
Answer streams back           → caption fills in word by word,
                                Aman starts speaking after the first sentence
If the answer says "#7"       → buddy flies to button #7 and a box glows around it
Follow-up ("and then?")       → works, because Claude remembers this conversation
```

### B. Open and do
```
You say something             → quick check first: can we do this without Claude?
  "open Spotify"              → yes → open it right away (no Claude)
  "search flights to Pune"    → yes → open Chrome with that search (no Claude)
  anything else               → Claude picks a tool from our toolbox (section 5)
Tool sends or posts something → confirm card → you press Enter → it happens
Done                          → buddy says "done" / "sent to Rahul"
```

### C. Meeting notes
```
Window or menu bar → Start (Granola style: no bot joins the call)
  or: a Google Meet, Zoom or Teams call opens → short "Transcribe Google Meet?" bar → Start
  → the bar stays up the whole time with a timer, Pause or Resume, and Stop (bottom left, draggable)
  → when the call ends, the bar says "Call ended". It keeps listening until you choose
  → also from the Meetings page, the menu bar, or by saying "pause the notes"
  → listens to your mic ("You") and the Mac's sound ("Them")
  → turns speech into text live, on your Mac; you can jot rough notes alongside
Stop
  → only the text goes to Claude (not the audio)
  → Meetings page: notes built from your jottings + the transcript, action items, full transcript, Copy
  → saved as text only in ~/Library/Application Support/Case/meetings/
```

---

## 4. How it works inside

```
┌───────────────────────────── Case (Swift app) ─────────────────────────────┐
│                                                                                 │
│  👀 Eyes            👂 Ears              🗣 Voice           ✋ Hands             │
│  ScreenCaptureKit   SpeechAnalyzer +     Apple speech       Toolbox server       │
│  + Accessibility    SpeechTranscriber    engine (Aman       (open, WhatsApp,     │
│  button list        (en-IN)              Premium)           Mail, click, …)      │
│                                                                                 │
│  💬 Face: buddy overlay, caption, confirm cards, meeting pill                    │
│                                                                                 │
│  🧠 Router: "easy? do it now. needs thinking? ask Claude."                       │
└───────────────────────────────────────┬─────────────────────────────────────────┘
                                        │ pipe (stream-json in, stream-json out)
                                        ▼
                         ┌──────────────────────────────┐
                         │ claude (your installed CLI)  │  started once, kept running
                         │ uses your Claude plan        │
                         └──────────────────────────────┘
```

| Part | Apple feature used |
|---|---|
| Hotkey (tap vs hold) | Watches ⌥⌘ through global and local event monitors; hold longer than ~0.25s = talk; any other key or click cancels |
| Buddy + highlights | Transparent, click-through, always-on-top window on each screen |
| Screenshot | ScreenCaptureKit, our own windows hidden, shrunk to max 1280px wide, JPEG |
| Button list | Accessibility API: visible buttons, links, fields and menu items of the front app, with exact positions (capped at ~150 items). Chrome and Electron apps (Notion, Slack, VS Code) hide this list until we switch it on: set `AXEnhancedUserInterface` (Chrome) or `AXManualAccessibility` (Electron) on the app first. For web pages the list can still be thin, so the screenshot `[POINT:x,y]` fallback is a **main path** there, not a rare backup. |
| Listening | `SpeechAnalyzer` + `SpeechTranscriber`, locale **en-IN** (already installed, tested) |
| Speaking | Apple speech engine, voice `com.apple.voice.Aman.premium` (already installed, tested). It's only listed by the older `NSSpeechSynthesizer` API, not by `AVSpeechSynthesisVoice.speechVoices()`, so we use that API or check that the newer one can load it by its identifier |
| Meeting audio | ScreenCaptureKit system audio + microphone |
| Contacts lookup | Contacts framework (to find "Rahul's" number) |
| Mail / Spotify control | AppleScript |

---

## 5. Connecting to Claude

**How:** the app starts your `claude` command **once** at launch, in "keep talking" mode, and sends
each question down the same pipe. Nothing restarts between questions, so answers start faster.

```
cd ~/Library/Application\ Support/Case      # its own folder, not a project folder
claude -p --input-format stream-json --output-format stream-json --verbose \
       --model <from Settings> \
       --setting-sources "" --disable-slash-commands \
       --tools "" \
       --allowedTools "mcp__case__*" "<Notion connector tools>" \
       --mcp-config '{"mcpServers":{"case":{"type":"http","url":"http://127.0.0.1:<port>/mcp","headers":{"Authorization":"Bearer <secret>"}}}}' \
       --append-system-prompt "<buddy instructions>"
```

**Tested on this Mac (2026-10-29):** one kept-alive `claude` with a screenshot sent through the pipe
understood the image (first answer in **2.1 sec**), and a follow-up on the same pipe remembered it
(**1.7 sec**). Startup is about 1 sec, and it happens once at launch.

**Kept separate from your own Claude Code setup:**
- `--setting-sources ""` + `--disable-slash-commands`: your personal CLAUDE.md, hooks, plugins and
  skills don't load into the buddy (faster, and no unrelated instructions).
- **No** `--strict-mcp-config`, because it would also switch off your claude.ai connectors like Notion.
- `--tools ""` switches off Claude's built-in tools (files, terminal). `--allowedTools` lets through only
  our toolbox and Notion. In `-p` mode nothing can pop up a permission question, so this list is the whole rule.
- The toolbox server lives inside our app, so Claude reaches it over **HTTP on 127.0.0.1** with a
  secret key (a stdio command can't talk to a running app).

Rules (from Sentient OS's notes, written in our own code):
- Send everything through the pipe (stdin), never as a command-line argument.
- **Never** use `--bare`, because it breaks your Claude plan login.
- **Never** change Claude's settings folder (`CLAUDE_CONFIG_DIR`), because that logs you out.
- Check that Claude is installed and logged in with `claude auth status` and show a clear message if not.
- We never read, copy or store your Claude login details.
- If you hit your limit, the buddy says so. The reset time is read from the rate-limit event in Claude's
  output stream, not guessed. On subscription plans, `claude -p` may use a separate monthly
  Agent SDK credit rather than the normal chat limit.

**Model:** Sonnet by default. A "Fast" setting switches to Haiku.

**Buddy instructions (the system prompt) tell Claude to:**
- Answer in 1 or 2 short, spoken-style sentences unless you ask for more.
- When pointing helps, end with `[POINT:#7]` (a button number from the list).
  If the thing isn't in the list, use `[POINT:x,y]` on the screenshot. If pointing doesn't help, use `[POINT:none]`.
- Use the toolbox for actions, and never claim something was sent unless the tool said so.

**Memory:** the same Claude session is reused for follow-ups. A fresh session starts:
- after 10 minutes idle, or when you pick "New chat";
- after **8 turns or 10 screenshots, once you've stopped for 2 minutes**, because every turn adds a screenshot
  and old screenshots make answers slower and use more of your credit. Haiku writes short notes in that quiet
  moment, and the next question carries them, so follow-ups still make sense;
- at **12 turns or 15 screenshots** if there's never a quiet moment. That uses the last few turns as text, with no wait.

To keep restarts invisible, the app always has the **next** `claude` already started and waiting.
Switching sessions is instant.

---

## 6. The toolbox (how "open and do" works)

Our app runs a small private tool server (only reachable from your Mac, protected by a secret key).
Claude can only use these tools, and the app does the actual work.

| Tool | What the app does | Asks first? |
|---|---|---|
| `open_app(name)` | Launches the app | No |
| `open_url(url)` | Opens the link in Chrome / your default browser | No |
| `whatsapp_send(contact, text)` | Finds the number in Contacts → opens WhatsApp chat with the text filled in → presses Send | **Yes** |
| `mail_draft(to, subject, body)` | Creates a draft in Apple Mail | No (draft only) |
| `mail_send(...)` | Sends the email | **Yes** |
| `music(action, query?)` | Spotify play / pause / next / search | No |
| `click(#n)` | Presses button #n from the button list | **Yes**, if the button sends, posts, buys or deletes |
| `type_text(text)` | Types into the focused field | No |
| `press_key(key)` | Presses Enter, Tab, etc. | **Yes**, if it would send something |
| `point(#n or x,y)` | Moves the buddy and highlights the spot | No |
| Notion | Claude Code's own Notion connector (you connect it once) | **Yes** for writes |

- The **app** enforces "ask first", not Claude. Nothing gets sent without your Enter.
- Two contacts with the same name → the card asks which one.
- Unknown app → Claude looks, clicks, then looks again. This is slowest, so it's the last resort.

---

## 7. Speed targets

| Moment | Target |
|---|---|
| Press hotkey → buddy/box appears | under 0.1 sec |
| "Open X" (no Claude) | under 0.3 sec |
| Let go → first words on screen | about 1–2 sec |
| First words → Aman starts speaking | right after the first full sentence |

How: Claude is always running, screenshots are shrunk, answers stream, speaking starts sentence by sentence,
and easy tasks skip Claude completely.

---

## 8. Permissions (asked once, with a friendly setup screen)

| Permission | Why |
|---|---|
| Screen Recording | Screenshots and meeting audio |
| Accessibility | Hotkey, button list, clicking and typing |
| Microphone | Voice and meetings |
| Speech Recognition | Turning your voice into text |
| Contacts | Finding who "Rahul" is |
| Automation (per app) | Controlling Mail and Spotify |

First-run setup goes one step at a time: Claude Code, permissions, accent and Apple's speech model, then how to use Case. Kokoro keeps downloading in the background, and Apple's voice speaks until it's ready.

---

## 9. Build order

Each step is usable on its own.

| Step | What we build | Done when |
|---|---|---|
| **0. Setup** | Install Xcode. Create the project: menu bar icon, permission setup screen, Claude check (`claude auth status`). | App runs, shows ✦ in the menu bar, says "Claude Code connected". Also confirm that `--tools ""` still lets our toolbox and Notion tools through (not tested yet). |
| **1. Ask about screen (typed)** | Tap ⌥ Space → text box → screenshot + question → Claude kept running → answer streams into a caption | Typing "what is this?" on any screen gives a correct answer, first words within ~2 sec |
| **2. Voice** | Hold ⌥ Space to talk (live words), Aman speaks the answer, mute button, memory + New chat | Full spoken conversation with follow-ups |
| **3. Buddy + pointing** | Buddy follows the cursor, button list (incl. switching it on for Chrome/Electron), flies to `[POINT:#n]` or `[POINT:x,y]`, glowing box | "Where do I click to share?" → buddy lands on the right button |
| **4. Open and do** | Toolbox server, quick no-Claude path, WhatsApp / Mail / Chrome / Spotify, confirm card | "Message Rahul I'll be late" → card → Enter → sent |
| **5. Notion** | Connect Notion in Claude Code, "add to my to-do" | Item appears in Notion |
| **6. Meeting notes** | Mic + call audio, live transcript, jotted notes, notes and action items, saved transcript. Built 2026-10-31, real call not yet tested | A 5-min test call gives correct action items |
| **6a. Window, saved chats, memory** | One window with Chats, Meetings and Memory. Chats saved as text and continued there. Facts learned at the end of each chat, plus remember and forget tools | Built 2026-10-31 |
| **7. Polish + Codex** | Settings (voice, model, hotkey), usage-limit messages, Codex as a second brain (`codex app-server`) | Daily use with no rough edges |

---

## 10. Not now (maybe later)

- Hindi speech (Apple's new engine doesn't support it; would need Whisper)
- Windows version
- Wake word ("Hey buddy")
- Sharing the app with others: needs Apple's $99/year signing, and each person uses their own Claude login

---

## 11. Before we start

1. Install **Xcode** from the App Store (free, around 10 GB). The current command-line tools are
   mismatched (SDK 27 vs Swift 6.3), and Xcode signing keeps Mac permissions from resetting on every rebuild.
2. Open Xcode once to accept its license.
3. Then we start **Step 0**.
