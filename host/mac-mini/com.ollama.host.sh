#!/bin/zsh
# Ollama environment for the CoralStack Mac mini — the executable copy of what
# PROXMOX_MIGRATION.md Phase 4c describes in prose. See docs/MAC_MINI.md.
#
# WHY A LAUNCHAGENT AT ALL: Ollama here is the official Mac app (a menu-bar GUI
# app, chosen over Homebrew because it auto-updates and ships the CLI). A GUI
# app inherits its environment from the GUI launchd domain, so the only way to
# give it these five vars at every login is `launchctl setenv` from an agent
# that runs during session bootstrap.
#
# THE RACE THIS GUARDS AGAINST: the Ollama app registers itself as a macOS Login
# Item via SMAppService when "Start Ollama on login" is on (the default). So two
# things race at boot — this agent (which sets the env) and the Login Item
# (which launches the app). LaunchAgents with RunAtLoad fire during session
# bootstrap, BEFORE loginwindow processes Login Items, so the agent should win —
# but macOS does not document that ordering, so the self-heal below assumes it
# might not.

launchctl setenv OLLAMA_HOST 0.0.0.0            # bind all interfaces; default loopback is unreachable from the apps VM
launchctl setenv OLLAMA_FLASH_ATTENTION 1       # prerequisite for KV cache quantization on Apple Silicon
launchctl setenv OLLAMA_KV_CACHE_TYPE q8_0      # halves KV cache memory at long contexts, minimal quality cost
launchctl setenv OLLAMA_KEEP_ALIVE -1           # keep models resident; default 5min unload costs a ~10s reload per idle gap

# OLLAMA_NUM_PARALLEL — concurrent request slots. 4 caused KV-cache slot
# eviction on ~60k+ token conversations: coming back to a conversation after a
# subagent had run forced a full cold re-prefill (~2 min for a 61k prompt).
# 2 was the fix and the value is unchanged.
#
# THIS COMMENT USED TO READ "2 slots × 131072 tokens". That figure does not
# describe this box. Measured 2026-10-14: the live context is **32768**, and
# `OLLAMA_CONTEXT_LENGTH` is set nowhere — not here, not in the plist, not in
# ~/.coralstack/ollama.env, and not in the running server's environment (checked
# with `ps eww` on the ollama pid). 131072 came from arithmetic over an assumed
# 262144-token model context, carried over from PROXMOX_MIGRATION.md Phase 4c;
# nothing ever configured it.
#
# Left as a comment fix on purpose. Setting a context length here would reload
# the resident model, and this box is serving. Note the open question it
# leaves, which is worth measuring before anyone tunes this: the original
# rationale for 2 was "keep each slot large enough for long single-request
# contexts", and at a 32768 context that rationale no longer computes — the
# ~60k conversations that motivated the change cannot fit in any slot. The
# value 2 is still defensible on concurrency grounds; the sizing argument
# behind it is not, and the two were conflated.
launchctl setenv OLLAMA_NUM_PARALLEL 2

# Defensive self-heal — if the Login Item beat us, the running Ollama has no env
# vars. Detect that and restart it so it picks them up.
sleep 3
PID=$(pgrep -x ollama | head -1)
if [ -n "$PID" ] && ! ps eww -p "$PID" | grep -q OLLAMA_KV_CACHE_TYPE; then
  pkill -if 'Ollama.app' 2>/dev/null
  pkill -ix ollama 2>/dev/null
  sleep 2
  open -a Ollama
fi
