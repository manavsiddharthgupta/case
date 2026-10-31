# Case

A native Mac assistant that sees your screen, listens, talks back, and does tasks for you. It runs on your own Claude Code, with no API keys.

## How it works

Hold **⌥⌘** to talk, or tap it to type. Press **Esc** to stop.

Case answers beside your cursor, out loud, and can point at the thing you're asking about. Ask it to do something and it works through your apps for you, telling you what it's doing as it goes.

## What it can do

- **Answer questions about your screen:** ask what something means or where to click, and it points to the spot.
- **Do tasks:** open apps, click, type, scroll, read web pages, search the web, and find and open files.
- **Take meeting notes:** it offers to transcribe Google Meet, Zoom, and Teams calls, or you can press Start. There's no bot in the call, and the audio isn't kept.
- **Keep your chats:** continue any saved chat from the main window.
- **Remember you:** it picks up useful facts over time, and you can view, add, or delete them.

Case asks before anything that sends, posts, deletes, or buys, and it never types into password fields.

## Requirements

- Apple Silicon Mac on macOS 26 or later
- [Claude Code](https://claude.com/claude-code) installed and signed in, with a paid Claude plan
- Xcode, to build from source

Case understands English only for now.

## Build from source

1. Open `Case.xcodeproj` in Xcode.
2. Choose your own team under Signing & Capabilities.
3. Press ⌘R.

The first launch walks you through Claude Code, permissions, and a voice accent. Case needs Accessibility, Screen Recording, Microphone, and Speech Recognition, and it asks for your Desktop, Documents, and Downloads folders when it searches them.

## Privacy

Your data never goes to a Case server. Your questions, and screenshots when you ask from another app, go to Claude through your Claude Code account. Meeting transcripts go the same way when your notes are written.

Speech recognition and the voice both run on your Mac. Chats, meeting notes, and memory are saved locally in `~/Library/Application Support/Case`.

## Built with

- [speech-swift](https://github.com/soniqo/speech-swift) for the Kokoro voice
- [Sparkle](https://github.com/sparkle-project/Sparkle) for updates
- Apple's speech recognition, ScreenCaptureKit, and Accessibility APIs
