# ============================================================================
# Session-management patches for Claude Desktop (sourced by patch.sh).
#
#   1. start_session typed-turn guard: start_session refuses to start a session unless the turn was
#      typed by the user ("Start sessions only on the user's own words to you here; ...").
#      Guard: `if(n==="start"&&!cz(e))throw Error(r.owedTaskId===void 0?...` — we prepend `!1&&`.
#   2. wake cap: side-session reports wake the parent at most 10 times since the user's last message,
#      then wait until the user writes. `wakeWaitsForPerson(e){return(e.sideSessionWakesSinceUserMessage??0)>=10||...`
#   3. start cap: after 10 starts since the user's last message, the remembered "always new session"
#      choice is ignored and the user is asked again. `r==="new_session"&&(n.sideSessionStartsSinceUserMessage??0)>=10?"yes"`
#   Caps 2 and 3 are raised to SIDE_CAP.
#
# Minified aliases change per release, so everything is matched by regex. Each patch self-verifies
# (exactly one marker, file still parses) and aborts the build otherwise. Checked on 2.42304.0.
# ============================================================================

SIDE_CAP=50
STARTSESS_ANCHOR="Start sessions only on the user's own words"
STARTSESS_MARKER="start_session typed-turn guard disabled (local patch)"
WAKECAP_MARKER="side-session wake cap raised (local patch)"
STARTCAP_MARKER="side-session start cap raised (local patch)"

_sp_die() { echo "  [X] $1" >&2; exit 1; }
_sp_ok()  { echo "  [+] $1"; }

# apply_session_patches <.vite/build dir>
apply_session_patches() {
    local build_dir="$1" target n marker

    echo ""; echo "► Disabling the start_session typed-turn guard..."
    target=$(grep -lF "$STARTSESS_ANCHOR" "$build_dir"/*.js 2>/dev/null | head -1) || true
    [ -n "$target" ] || _sp_die "start_session guard not found — Claude Desktop internals changed. Aborting (no broken app produced)."
    n=$(grep -oF "$STARTSESS_ANCHOR" "$target" | wc -l | tr -d ' ')
    [ "$n" = "1" ] || _sp_die "expected 1 start_session guard, found $n in $(basename "$target") — aborting to avoid mispatch"
    MARK="$STARTSESS_MARKER" perl -0777 -i -pe 'BEGIN{$m=$ENV{MARK}} s/if\((\w+)==="start"&&!([\w.]+)\(([\w,]+)\)\)throw Error\((\w+)\.owedTaskId===void 0\?/if(!1\/*$m*\/&&$1==="start"&&!$2($3))throw Error($4.owedTaskId===void 0?/' "$target"
    n=$(grep -oF "$STARTSESS_MARKER" "$target" | wc -l | tr -d ' ')
    [ "$n" = "1" ] || _sp_die "verification failed: start_session marker count=$n (expected 1) — guard shape changed"
    node --check "$target" || _sp_die "patched $(basename "$target") does not parse"
    _sp_ok "start_session guard disabled in $(basename "$target")"

    echo ""; echo "► Raising the side-session wake and start caps to $SIDE_CAP..."
    target=$(grep -lF "wakeWaitsForPerson(" "$build_dir"/*.js 2>/dev/null | head -1) || true
    [ -n "$target" ] || _sp_die "side-session caps not found — Claude Desktop internals changed. Aborting (no broken app produced)."
    WM="$WAKECAP_MARKER" SM="$STARTCAP_MARKER" CAP="$SIDE_CAP" perl -0777 -i -pe '
        BEGIN{$wm=$ENV{WM};$sm=$ENV{SM};$c=$ENV{CAP}}
        s/wakeWaitsForPerson\((\w+)\)\{return\(\1\.sideSessionWakesSinceUserMessage\?\?0\)>=10\|\|/wakeWaitsForPerson($1){return($1.sideSessionWakesSinceUserMessage??0)>=$c\/*$wm*\/||/;
        s/(\w+)==="new_session"&&\((\w+)\.sideSessionStartsSinceUserMessage\?\?0\)>=10\?"yes"/$1==="new_session"&&($2.sideSessionStartsSinceUserMessage??0)>=$c\/*$sm*\/?"yes"/;
    ' "$target"
    for marker in "$WAKECAP_MARKER" "$STARTCAP_MARKER"; do
        n=$(grep -oF "$marker" "$target" | wc -l | tr -d ' ')
        [ "$n" = "1" ] || _sp_die "verification failed: '$marker' count=$n (expected 1) — cap shape changed"
    done
    node --check "$target" || _sp_die "patched $(basename "$target") does not parse"
    _sp_ok "wake + start caps raised to $SIDE_CAP in $(basename "$target")"
}

# verify_session_patches <repacked app.asar>
verify_session_patches() {
    local asar="$1" marker
    for marker in "$STARTSESS_MARKER" "$WAKECAP_MARKER" "$STARTCAP_MARKER"; do
        LC_ALL=C grep -aq "$marker" "$asar" || _sp_die "'$marker' missing from repacked asar"
    done
    _sp_ok "session patches present in repacked asar"
}
