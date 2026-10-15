#!/usr/bin/env bash
# Builds a small CLI from the app's own logic files and runs the end-to-end checks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/build/yamvideo-tests"
mkdir -p "$ROOT/build"

xcrun swiftc \
	-target "$(uname -m)-apple-macos14.0" \
	-sdk "$(xcrun --show-sdk-path --sdk macosx)" \
	-o "$BIN" \
	"$ROOT/Sources/Models.swift" \
	"$ROOT/Sources/Timeline.swift" \
	"$ROOT/Sources/ColorLUT.swift" \
	"$ROOT/Sources/ColorAdjustments.swift" \
	"$ROOT/Sources/ColorPipeline.swift" \
	"$ROOT/Sources/ColorEditing.swift" \
	"$ROOT/Sources/VisualEffects.swift" \
	"$ROOT/Sources/VisualEffectsEditing.swift" \
	"$ROOT/Sources/AgentCatalog.swift" \
	"$ROOT/Sources/AudioAnalysis.swift" \
	"$ROOT/Sources/AutoEdit.swift" \
	"$ROOT/Sources/AutoEditing.swift" \
	"$ROOT/Sources/Whisper.swift" \
	"$ROOT/Sources/Movie.swift" \
	"$ROOT/Sources/ZoomSuggestions.swift" \
	"$ROOT/Sources/MoviePlayback.swift" \
	"$ROOT/Sources/MovieEditing.swift" \
	"$ROOT/Sources/Playback.swift" \
	"$ROOT/Sources/Graphics.swift" \
	"$ROOT/Sources/Shorts.swift" \
	"$ROOT/Sources/ShortsEditing.swift" \
	"$ROOT/Sources/ShortsAgents.swift" \
	"$ROOT/Sources/EndScreen.swift" \
	"$ROOT/Sources/GraphicsRender.swift" \
	"$ROOT/Sources/Publish.swift" \
	"$ROOT/Sources/Captions.swift" \
	"$ROOT/Sources/PublishEditing.swift" \
	"$ROOT/Sources/Thumbnail.swift" \
	"$ROOT/Sources/GraphicsEditing.swift" \
	"$ROOT/Sources/GraphicsOverlay.swift" \
	"$ROOT/Sources/GraphicsPlacement.swift" \
	"$ROOT/Sources/AppModel.swift" \
	"$ROOT/Sources/ProjectEditing.swift" \
	"$ROOT/Sources/EditCommands.swift" \
	"$ROOT/Sources/ProjectCommandDispatcher.swift" \
	"$ROOT/Sources/AgentProtocol.swift" \
	"$ROOT/Sources/LocalAgentServer.swift" \
	"$ROOT/Sources/AgentRequests.swift" \
	"$ROOT/Sources/AgentActivityView.swift" \
	"$ROOT/Sources/Shell.swift" \
	"$ROOT/Sources/FFmpeg.swift" \
	"$ROOT/Sources/CropEditor.swift" \
	"$ROOT/Tests/main.swift"

# The CLI too, so the checks can drive a real separate process over the socket.
xcrun swiftc \
	-target "$(uname -m)-apple-macos14.0" \
	-sdk "$(xcrun --show-sdk-path --sdk macosx)" \
	-o "$ROOT/build/yamvideoctl" \
	"$ROOT/Sources/AgentProtocol.swift" "$ROOT/Tools/YamVideoCLI/main.swift"

YAMVIDEO_ROOT="$ROOT" YAMVIDEO_CTL="$ROOT/build/yamvideoctl" "$BIN"
