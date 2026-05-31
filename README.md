# Agent Keeper

Agent Keeper is a small macOS menu bar app for keeping track of local AI agent sessions. It watches Claude Code, Claude Desktop, Claude Cowork, Codex CLI, and Codex Desktop, then groups active sessions by state: needs attention, working, or idle.

It can install lightweight hooks for Claude Code and Codex CLI, read local session files for desktop and CLI apps, show a status icon, play a sound when an agent needs attention, and jump back to the relevant app or terminal session when you click a row.

## Features

- Menu bar overview of active AI agent sessions.
- "Needs attention", "working", and "idle" state grouping.
- Claude Code notification hook installer.
- Codex CLI notify wrapper that preserves an existing notify target.
- Desktop app detection for Claude Desktop, Claude Cowork, and Codex Desktop.
- Optional Accessibility-based detection for desktop app approval prompts and dock badges.
- Diagnostics view for hook and producer health.

## Requirements

- macOS 14 or newer.
- Xcode with Swift 5.10 support.
- XcodeGen for generating the Xcode project from `project.yml`.

## Build

```sh
xcodegen generate
xcodebuild -project AgentKeeper.xcodeproj -scheme AgentKeeperApp -configuration Debug build
```

Open the generated `AgentKeeper.xcodeproj` in Xcode for local development. The project uses ad-hoc signing by default; set your own team or signing identity locally if macOS Accessibility permissions need to persist across rebuilds.

## Notes

The app writes status JSON files under `~/Library/Application Support/AgentKeeper/status`. Hook installers back up modified Claude and Codex config files before writing changes.
