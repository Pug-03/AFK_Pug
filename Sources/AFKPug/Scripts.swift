/// Shell scripts AFK Pug writes to ~/.afkpug/bin.
enum Scripts {
    /// Called by agent hooks: afkpug-hook <action> <agent>  (hook JSON on stdin)
    ///   start  prompt submitted (UserPromptSubmit, BeforeAgent, beforeSubmitPrompt): create the hold
    ///   touch  tool calls: re-arm the hold (recreate it if missing or if it is a usage-limit hold)
    ///   stop   turn end (Stop, AfterAgent, Cursor stop): drop the hold, "done" event
    ///          (Cursor: status "aborted" = end, "error" = fail)
    ///   notify Claude Notification: by notification_type
    ///   wait   permission prompt (Gemini Notification, Codex PermissionRequest): "waiting" event, hold kept
    ///   fail   Claude StopFailure: drop the hold, "failed" event; a usage limit with a reset
    ///          time keeps an expiring hold until then (so Claude can continue on its own)
    ///   end    session end / interrupt: drop the hold
    /// Session id: session_id (Claude, Gemini, Codex) or conversation_id (Cursor).
    static let hook = #"""
    #!/bin/sh
    # AFK Pug agent hook. Usage: afkpug-hook start|touch|stop|notify|wait|fail|end <agent>
    # Always exits 0 and prints nothing (stdout of UserPromptSubmit becomes context).
    action="$1"; agent="${2:-agent}"
    input=$(head -c 65536 2>/dev/null)
    # First match of a string key (tool_input can contain another one).
    field() { printf '%s' "$input" | LC_ALL=C grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | LC_ALL=C sed 's/.*"\([^"]*\)"$/\1/'; }
    # Cursor also runs Claude Code's hooks from ~/.claude/settings.json: count those as Cursor.
    [ "$agent" = claude ] && case "$input" in *'"cursor_version"'*) agent=cursor ;; esac
    case "$agent" in cursor) sid=$(field conversation_id); [ -z "$sid" ] && sid=$(field session_id) ;;
      *) sid=$(field session_id); [ -z "$sid" ] && sid=$(field conversation_id) ;; esac
    sid=$(printf '%s' "$sid" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c 1-80)
    [ -z "$sid" ] && sid="$PPID"
    agent=$(printf '%s' "$agent" | LC_ALL=C tr -c 'A-Za-z0-9_' '_' | cut -c 1-40)
    root="$HOME/.afkpug"; mkdir -p "$root/holds" "$root/events" 2>/dev/null
    hold="$root/holds/$agent-$sid"
    now=$(date +%s)
    event() { : > "$root/events/$now$$-$agent-$1"; }
    # The agent process that owns this hold (skip an intermediate sh -c), so the
    # app can drop the hold if the agent is killed without running its Stop hook,
    # and keep it while the agent's process tree is busy.
    # create [expires] [reason]
    create() {
      owner="$PPID"
      case "$(basename "$(ps -o comm= -p "$owner" 2>/dev/null)" 2>/dev/null)" in
        sh|bash|zsh|dash|-sh|-bash|-zsh) owner=$(ps -o ppid= -p "$owner" 2>/dev/null | tr -d ' ') ;;
      esac
      case "$owner" in ''|*[!0-9]*|0|1) owner=0 ;; esac
      extra=""; [ -n "$2" ] && extra=",\"reason\":\"$2\""
      tmp="$root/holds/.$agent-$sid.$$.tmp"
      printf '{"agent":"%s","started":%s,"expires":%s,"pid":%s%s}\n' "$agent" "$now" "${1:-0}" "$owner" "$extra" > "$tmp" && mv -f "$tmp" "$hold"
    }
    # Epoch of the reset in a usage-limit message ("... · resets 3:45pm",
    # "resets Mon 12:00am", "resets 2026-08-09 00:00 UTC"), in local time; empty if none.
    reset_at() {
      r=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C sed -n 's/.*resets[[:space:]]*\(at[[:space:]]*\)\{0,1\}//p' | head -n 1 | cut -c 1-40)
      [ -z "$r" ] && return
      d=$(printf '%s' "$r" | LC_ALL=C sed -nE 's/^([0-9]{4}-[0-9]{2}-[0-9]{2})[ t]([0-9]{1,2}:[0-9]{2}).*/\1 \2/p')
      if [ -n "$d" ]; then
        case "$r" in *utc*|*z\ *|*z) date -u -j -f '%Y-%m-%d %H:%M:%S' "$d:00" +%s 2>/dev/null ;;
          *) date -j -f '%Y-%m-%d %H:%M:%S' "$d:00" +%s 2>/dev/null ;; esac
        return
      fi
      wd=$(printf '%s' "$r" | LC_ALL=C sed -nE 's/^(mon|tue|wed|thu|fri|sat|sun)[a-z]*,?[[:space:]]+.*/\1/p')
      [ -n "$wd" ] && r=$(printf '%s' "$r" | LC_ALL=C sed -E 's/^[a-z]+,?[[:space:]]+//')
      t=$(printf '%s' "$r" | LC_ALL=C sed -nE 's/^([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*(am|pm)?.*/\1 \3 \4/p')
      [ -z "$t" ] && return
      set -- $t
      h=$(expr "$1" + 0); m=0; ap=""
      case "$2" in [0-9]*) m=$(expr "$2" + 0); ap="$3" ;; *) ap="$2" ;; esac
      case "$ap" in am) [ "$h" -eq 12 ] && h=0 ;; pm) [ "$h" -lt 12 ] && h=$((h + 12)) ;; esac
      [ "$h" -gt 23 ] || [ "$m" -gt 59 ] && return
      at=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) $h:$m:00" +%s 2>/dev/null) || return
      if [ -n "$wd" ]; then
        i=1; for w in mon tue wed thu fri sat sun; do [ "$w" = "$wd" ] && break; i=$((i + 1)); done
        at=$((at + (i - $(date +%u) + 7) % 7 * 86400))
        [ "$at" -le "$now" ] && at=$((at + 7 * 86400))
      else
        [ "$at" -le "$now" ] && at=$((at + 86400))
      fi
      echo "$at"
    }
    case "$action" in
      start) create ;;
      touch)
        # A usage-limit hold (fixed expiry) turns back into a normal one when work resumes.
        if [ -f "$hold" ] && LC_ALL=C grep -q '"expires":0,' "$hold"; then touch "$hold"; else create; fi ;;
      stop)
        [ "$agent" = cursor ] && case "$(field status)" in
          aborted) rm -f "$hold"; exit 0 ;;                                  # Cursor: user stopped it
          error) [ -f "$hold" ] && { rm -f "$hold"; event failed; }; exit 0 ;;
        esac
        # Background shells / builds still running: the session isn't done.
        if printf '%s' "$input" | LC_ALL=C grep -q '"background_tasks"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^][:space:]]'; then
          [ -f "$hold" ] && touch "$hold"
        elif [ -f "$hold" ]; then
          rm -f "$hold"
          # Another Stop hook is continuing the turn: no "finished" yet.
          printf '%s' "$input" | LC_ALL=C grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' || event done
        fi ;;
      notify)
        case "$(field notification_type)" in
          permission_prompt|elicitation_dialog|elicitation_url_dialog) [ -f "$hold" ] && event waiting ;;
          idle_prompt) rm -f "$hold" ;;   # back at the prompt (e.g. after Esc)
          quota_auto_resume_fired) create ;;   # usage limit reset: Claude continues the task
          quota_auto_resume_stale|quota_auto_resume_disabled) rm -f "$hold" ;;   # not continuing
        esac ;;
      wait) [ -f "$hold" ] && event waiting ;;
      fail)
        # StopFailure. A claude.ai usage limit: Claude Code waits and continues the
        # task after the reset, so stay awake until then (at most 6 h). A plain
        # throttle ("not your usage limit") or any other API error releases.
        until=""
        if [ "$(field error)" = rate_limit ]; then
          msg="$(field last_assistant_message) $(field error_details)"
          case "$msg" in
            *"not your usage limit"*) ;;
            *) until=$(reset_at "$msg")
               case "$until" in
                 ''|*[!0-9]*) until=$((now + 1800)) ;;          # no reset time given: 30 min
                 *) if [ "$until" -gt $((now + 21600)) ]; then until=""   # weekly limit days away
                    else until=$((until + 120)); fi ;;          # Claude continues shortly after
               esac ;;
          esac
        fi
        if [ -n "$until" ]; then
          create "$until" "usage limit"; event failed
        elif [ -f "$hold" ]; then
          rm -f "$hold"; event failed
        fi ;;
      end) rm -f "$hold" ;;
    esac
    exit 0
    """#

    /// User-facing CLI: afkpug hold | release | run | status
    static let cli = #"""
    #!/bin/sh
    # AFK Pug CLI
    dir="$HOME/.afkpug/holds"; mkdir -p "$dir"
    die() { echo "afkpug: $*" >&2; exit 2; }
    # 90s, 45m, 2h, 1h30m; a bare number means minutes. 1 s .. 24 h.
    secs() {
      v="$1"; total=0; num=""
      case "$v" in ''|*[!0-9hms]*) return 1 ;; esac
      while [ -n "$v" ]; do
        c=$(printf '%s' "$v" | cut -c 1); v=$(printf '%s' "$v" | cut -c 2-)
        case "$c" in
          [0-9]) num="$num$c"; [ ${#num} -gt 6 ] && return 1 ;;
          h|m|s)
            [ -z "$num" ] && return 1
            n=$(expr "$num" + 0); num=""
            case "$c" in h) total=$((total + n * 3600)) ;; m) total=$((total + n * 60)) ;; s) total=$((total + n)) ;; esac ;;
        esac
      done
      [ -n "$num" ] && total=$((total + $(expr "$num" + 0) * 60))
      [ "$total" -gt 0 ] && [ "$total" -le 86400 ] || return 1
      echo "$total"
    }
    human() { if [ "$1" -lt 60 ]; then echo "${1}s"; elif [ "$1" -lt 3600 ]; then echo "$(( $1 / 60 ))m"; else echo "$(( $1 / 3600 ))h$(( $1 % 3600 / 60 ))m"; fi; }
    running() { /bin/ps -U "$(/usr/bin/id -u)" -o args= | /usr/bin/grep -E 'AFK Pug\.app/Contents/MacOS/AFKPug( |$)' | /usr/bin/grep -vq -- '--mcp'; }
    usage() {
      cat <<EOF
    AFK Pug - keep your Mac awake while you're away
      afkpug hold [--for 30m|2h|1h30m] [--reason text]   keep awake for a while (default 30m, max 24h)
      afkpug release [id]                                drop a hold (all CLI and agent-tool holds if no id)
      afkpug run -- <command>                            keep awake while a command runs
      afkpug status                                      show what is keeping the Mac awake
    EOF
    }
    case "$1" in
      hold)
        shift; dur=1800; reason="manual"
        while [ $# -gt 0 ]; do
          case "$1" in
            --for) [ $# -ge 2 ] || die "--for needs a value (e.g. 30m, 2h)"
                   dur=$(secs "$2") || die "bad duration '$2' (use 30m, 2h, 1h30m; max 24h)"; shift 2 ;;
            --reason) [ $# -ge 2 ] || die "--reason needs a value"
                   reason=$(printf '%s' "$2" | LC_ALL=C tr -d '"\\\000-\037' | cut -c 1-200); shift 2 ;;
            *) die "unknown option '$1'" ;;
          esac
        done
        now=$(date +%s); id="cli-$now-$$"
        printf '{"agent":"cli","started":%s,"expires":%s,"reason":"%s"}\n' "$now" $((now + dur)) "$reason" > "$dir/$id"
        echo "AFK Pug holding for $(human "$dur")  (id: $id)"
        running || echo "Note: the AFK Pug app is not running, so this has no effect until it starts." >&2 ;;
      release)
        if [ -n "$2" ]; then
          case "$2" in .*|*[!A-Za-z0-9._-]*) die "bad id '$2'" ;; esac
          [ -f "$dir/$2" ] || die "no hold '$2'"
          rm -f "$dir/$2"
        else
          rm -f "$dir"/cli-* "$dir"/mcp-*
        fi
        echo "Released." ;;
      run)
        shift; [ "$1" = "--" ] && shift
        [ $# -eq 0 ] && die "usage: afkpug run -- <command>"
        id="run-$(date +%s)-$$"
        printf '{"agent":"%s","started":%s,"expires":0,"reason":"run","pid":%s}\n' "$(basename "$1" | LC_ALL=C tr -d '"\\\000-\037')" "$(date +%s)" "$$" > "$dir/$id"
        # Keep the hold fresh; must not hold the caller's stdout/stderr open.
        ( trap 'kill "$s" 2>/dev/null; exit 0' TERM
          while kill -0 $$ 2>/dev/null; do sleep 60 & s=$!; wait "$s"; [ -f "$dir/$id" ] && touch "$dir/$id"; done ) </dev/null >/dev/null 2>&1 &
        keepalive=$!
        trap 'kill "$keepalive" 2>/dev/null; rm -f "$dir/$id"' EXIT
        # Run in the background (stdin kept) so signals can be forwarded to it.
        "$@" <&0 &
        child=$!
        trap 'kill -TERM "$child" 2>/dev/null' TERM
        trap 'kill -INT "$child" 2>/dev/null' INT
        trap 'kill -HUP "$child" 2>/dev/null' HUP
        code=0
        while :; do
          wait "$child"; code=$?
          kill -0 "$child" 2>/dev/null || break
        done
        exit "$code" ;;
      status)
        if running; then echo "AFK Pug: running"; else echo "AFK Pug: not running (holds do nothing until it starts)"; fi
        now=$(date +%s); n=0
        for f in "$dir"/*; do
          [ -f "$f" ] || continue
          n=$((n + 1)); line="  - $(basename "$f")"
          reason=$(sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' "$f")
          exp=$(sed -n 's/.*"expires":\([0-9][0-9]*\).*/\1/p' "$f")
          [ -n "$reason" ] && line="$line  ($reason)"
          if [ -n "$exp" ] && [ "$exp" -gt 0 ]; then
            if [ "$exp" -le "$now" ]; then line="$line  [expired]"; else line="$line  [$(human $((exp - now))) left]"; fi
          fi
          echo "$line"
        done
        echo "Holds: $n" ;;
      ""|help|-h|--help) usage ;;
      *) usage >&2; exit 2 ;;
    esac
    """#

    /// Run by launchd every 30 s: if AFK Pug is gone, undo everything it left behind.
    /// `pgrep -x AFKPug` alone is wrong: `AFKPug --mcp` servers share the name.
    /// Match the app bundle's executable (the `\.` keeps grep from matching itself).
    static let watchdog = #"""
    #!/bin/sh
    state="$HOME/.afkpug/state"
    /bin/ps -U "$(/usr/bin/id -u)" -o args= | /usr/bin/grep -E 'AFK Pug\.app/Contents/MacOS/AFKPug( |$)' | /usr/bin/grep -vq -- '--mcp' && exit 0
    if [ -f "$state/paused-pids" ]; then
      xargs kill -CONT < "$state/paused-pids" 2>/dev/null; rm -f "$state/paused-pids"
    fi
    if [ -f "$state/lid-override" ]; then
      /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 && rm -f "$state/lid-override"
    fi
    if [ -f "$state/lowpower-restore" ]; then
      # The file names the power source we changed: b (battery) or c (charger).
      # Remove the flag only once the restore worked, so it is retried.
      case "$(cat "$state/lowpower-restore" 2>/dev/null)" in
        b) /usr/bin/sudo -n /usr/bin/pmset -b lowpowermode 0 && rm -f "$state/lowpower-restore" ;;
        c) /usr/bin/sudo -n /usr/bin/pmset -c lowpowermode 0 && rm -f "$state/lowpower-restore" ;;
        *) rm -f "$state/lowpower-restore" ;;
      esac
    fi
    if [ -f "$state/mute-restore" ]; then
      /usr/bin/osascript -e 'set volume output muted false' >/dev/null 2>&1; rm -f "$state/mute-restore"
    fi
    exit 0
    """#
}
