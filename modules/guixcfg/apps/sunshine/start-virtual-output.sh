#!/bin/sh
# Create the ephemeral virtual output for the current Moonlight client.
# Sunshine exports SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS to prep commands.
set -eu

w="${SUNSHINE_CLIENT_WIDTH:-3200}"
h="${SUNSHINE_CLIENT_HEIGHT:-2136}"
fps="${SUNSHINE_CLIENT_FPS:-60}"

# Remove a stale output from a previous crash, then create atomically.
niri msg remove-virtual-output virtual 2>/dev/null || true
niri msg create-virtual-output --name virtual --width "$w" --height "$h" --refresh-rate "$fps"

# Keep the UI scale close to the internal panel's logical width (1829);
# these are best-effort post-creation settings.
scale=$(awk -v w="$w" 'BEGIN { printf "%.2f", w / 1829 }')
niri msg output virtual scale "$scale" || true
niri msg output virtual position set 1829 0 || true
niri msg action focus-monitor virtual || true
