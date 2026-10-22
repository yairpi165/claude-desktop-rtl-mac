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
#   4. start-count card: after 10 starts, every further start shows an approval card (`Fd(l,o,s)>=10}`);
#      and an auto-accepted offer is refused past 10 (`r.auto&&(i.sideSessionStartsSinceUserMessage??0)>=10?`).
#   Caps 2-4 are raised to SIDE_CAP.
#   5. approval cards for routine session tools: forceAskVerdict() is the app's PreToolUse gate that
#      shows a card (or defers to the auto-mode classifier). For the tools in AUTO_ALLOW_TOOLS we
#      return {standDown:"bypass"}, so the app stays out of it; the CLI permission rules then decide
#      (patch.sh's allow rules / auto mode). delete/clear/permission-mode/remote-control/settings/
#      terminal/discard tools are NOT in the list and still ask.
#   6. archive "on_screen" hold: archive_session refuses a target the user can currently see unless the
#      card was approved. With no card (5) that hold would always fire, so it is disabled. The
#      running / pinned / losable_work (uncommitted changes) holds stay.
#   7. wake on every report: the parent is only woken once none of its other side sessions is still
#      working (wakeWaitsForSideSessions). The "others still working" clause is disabled so each report
#      wakes the parent as soon as it lands; a start still in flight keeps holding the wake.
#
# Minified aliases change per release, so everything is matched by regex. Each patch self-verifies
# (exactly one marker, file still parses) and aborts the build otherwise. Checked on 2.42304.0 (1-3)
# and 3.1623.3 (1-7).
# ============================================================================

SIDE_CAP=50
STARTSESS_ANCHOR="Start sessions only on the user's own words"
STARTSESS_MARKER="start_session typed-turn guard disabled (local patch)"
WAKECAP_MARKER="side-session wake cap raised (local patch)"
STARTCAP_MARKER="side-session start cap raised (local patch)"
COUNTCAP_MARKER="side-session start-count card cap raised (local patch)"
OFFERCAP_MARKER="side-session auto-offer cap raised (local patch)"
AUTOALLOW_MARKER="routine session tools skip approval card (local patch)"
ONSCREEN_MARKER="archive on_screen hold disabled (local patch)"
WAKEEACH_MARKER="parent wakes on each side-session report (local patch)"
AUTO_ALLOW_TOOLS="archive_session|unarchive_session|stop_session|set_session_model|set_session_effort|set_session_fast_mode|set_session_output_style|mark_completed|move_sessions|set_pinned|set_unread|request_keep_awake|set_monitor"

SP_APPLIED_OPTIONAL=()
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

    # 3.x only: absent in 2.x builds, so each is applied when its anchor exists and skipped otherwise.
    echo ""; echo "► Raising the start-count card and auto-offer caps to $SIDE_CAP..."
    _sp_optional "$build_dir" 'sideSessionStartToolUses' "$COUNTCAP_MARKER" \
        's/(\w+\((\w+),(\w+),(\w+)\))>=10\}(function \w+\(\w+,\w+,\w+\)\{let \w+=\w+\?\.sideSessionStartsSinceUserMessage)/$1>=$ENV{CAP}\/*$ENV{MARKER}*\/}$5/'
    _sp_optional "$build_dir" 'acceptSideSessionOffer(' "$OFFERCAP_MARKER" \
        's/(\w+)\.auto&&\((\w+)\.sideSessionStartsSinceUserMessage\?\?0\)>=10\?/$1.auto&&($2.sideSessionStartsSinceUserMessage??0)>=$ENV{CAP}\/*$ENV{MARKER}*\/?/'

    echo ""; echo "► Skipping approval cards for routine session tools..."
    _sp_optional "$build_dir" 'async forceAskVerdict(' "$AUTOALLOW_MARKER" \
        's/async forceAskVerdict\((\w+),(\w+),(\w+),(\w+),(\w+)\)\{/async forceAskVerdict($1,$2,$3,$4,$5){if(\/^mcp__ccd_[a-z_]+__(?:$ENV{TOOLS})\$\/.test($1))return{standDown:"bypass"}\/*$ENV{MARKER}*\/;/'
    _sp_optional "$build_dir" '"on_screen"' "$ONSCREEN_MARKER" \
        's/(\w+)&&!(\w+)&&this\.isSessionKnownVisible\((\w+)\.sessionId\)\?"on_screen"/!1\/*$ENV{MARKER}*\/&&$1&&!$2&&this.isSessionKnownVisible($3.sessionId)?"on_screen"/'

    echo ""; echo "► Waking the parent on each side-session report..."
    _sp_optional "$build_dir" 'wakeWaitsForSideSessions(' "$WAKEEACH_MARKER" \
        's/(wakeWaitsForSideSessions\((\w+),(\w+)\)\{return\(this\.deps\.sideSessionStartsInFlightGet\(\2\)\?\?0\)>0\|\|)(this\.deps\.liveSideSessionsOf\()/$1!1\/*$ENV{MARKER}*\/&&$4/'
}

# _sp_optional <build dir> <fixed-string probe> <marker> <perl substitution>
# The probe is a stable feature string (not a minified alias). No file has it => the feature is absent
# in this build (older 2.x) and the patch is skipped. Present but the substitution does not land exactly
# once => the code shape changed and the build aborts.
_sp_optional() {
    local build_dir="$1" probe="$2" marker="$3" subst="$4" files f n total=0 hit=""
    files=$(grep -lF "$probe" "$build_dir"/*.js 2>/dev/null) || true
    if [ -z "$files" ]; then echo "  [-] skipped (not in this build): $marker"; return 0; fi
    for f in $files; do
        CAP="$SIDE_CAP" MARKER="$marker" TOOLS="$AUTO_ALLOW_TOOLS" perl -0777 -i -pe "$subst" "$f"
        n=$( (grep -oF "$marker" "$f" || true) | wc -l | tr -d ' ')
        if [ "$n" != "0" ]; then
            total=$((total + n)); hit="$f"
            node --check "$f" || _sp_die "patched $(basename "$f") does not parse"
        fi
    done
    [ "$total" = "1" ] || _sp_die "verification failed: '$marker' count=$total (expected 1) — code shape changed"
    _sp_ok "$marker in $(basename "$hit")"
    SP_APPLIED_OPTIONAL+=("$marker")
}

# verify_session_patches <repacked app.asar>
verify_session_patches() {
    local asar="$1" marker
    for marker in "$STARTSESS_MARKER" "$WAKECAP_MARKER" "$STARTCAP_MARKER" ${SP_APPLIED_OPTIONAL[@]+"${SP_APPLIED_OPTIONAL[@]}"}; do
        LC_ALL=C grep -aq "$marker" "$asar" || _sp_die "'$marker' missing from repacked asar"
    done
    _sp_ok "session patches present in repacked asar"
}

# ensure_session_allow_rules
# Patch 5 makes the app stand down for AUTO_ALLOW_TOOLS; the Claude Code permission check then decides.
# Add matching allow rules to ~/.claude/settings.json so it does not ask either. Idempotent: only missing
# rules are added, other settings are left as they are, and a backup is kept when the file changes.
# Skipped with SKIP_ALLOW_RULES=1.
SP_ALLOW_RULES="mcp__ccd_session_mgmt__archive_session mcp__ccd_session_mgmt__unarchive_session mcp__ccd_session_mgmt__stop_session mcp__ccd_session_mgmt__set_session_model mcp__ccd_session_mgmt__set_session_effort mcp__ccd_session_mgmt__set_session_fast_mode mcp__ccd_session_mgmt__set_session_output_style mcp__ccd_session_mgmt__set_session_title mcp__ccd_sidebar__mark_completed mcp__ccd_sidebar__move_sessions mcp__ccd_sidebar__set_pinned mcp__ccd_sidebar__set_unread mcp__ccd_host__request_keep_awake mcp__ccd_pr__set_monitor"
ensure_session_allow_rules() {
    local settings="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
    echo ""; echo "► Adding Claude Code allow rules for routine session tools..."
    if [ "${SKIP_ALLOW_RULES:-0}" = "1" ]; then echo "  [-] skipped (SKIP_ALLOW_RULES=1)"; return 0; fi
    SETTINGS="$settings" RULES="$SP_ALLOW_RULES" node -e '
        const fs = require("fs"), path = require("path");
        const f = process.env.SETTINGS, rules = process.env.RULES.split(" ");
        let s = {};
        if (fs.existsSync(f)) {
            try { s = JSON.parse(fs.readFileSync(f, "utf8")); }
            catch (e) { console.error("  [!] " + f + " is not valid JSON; leaving it alone"); process.exit(0); }
        }
        s.permissions ??= {}; s.permissions.allow ??= [];
        const missing = rules.filter(r => !s.permissions.allow.includes(r));
        if (!missing.length) { console.log("  [+] allow rules already present in " + f); process.exit(0); }
        if (fs.existsSync(f)) fs.copyFileSync(f, f + ".bak-rtl-patch");
        else fs.mkdirSync(path.dirname(f), { recursive: true });
        s.permissions.allow.push(...missing);
        fs.writeFileSync(f, JSON.stringify(s, null, 2) + "\n");
        console.log("  [+] added " + missing.length + " allow rule(s) to " + f + " (backup: " + f + ".bak-rtl-patch)");
    ' || echo "  [!] could not update $settings — add the rules manually (see session-patches.sh)"
}
