/// Shell scripts AFK Pug writes to ~/.afkpug/bin.
enum Scripts {
    /// Called by agent hooks: afkpug-hook start|touch|stop|wait|end <agent>  (hook JSON on stdin)
    ///   start  UserPromptSubmit: create the hold
    ///   touch  PreToolUse / PostToolUse: re-arm the hold (recreate it if missing)
    ///   stop   Stop: drop the hold, "done" event
    ///   wait   Notification: "waiting" event; the hold stays (work resumes after approval)
    ///   end    SessionEnd: drop the hold
    static let hook = #"""
    #!/bin/sh
    # AFK Pug agent hook. Usage: afkpug-hook start|touch|stop|wait|end <agent>
    action="$1"; agent="${2:-agent}"
    input=$(cat 2>/dev/null)
    sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -z "$sid" ] && sid="$PPID"
    root="$HOME/.afkpug"; mkdir -p "$root/holds" "$root/events"
    hold="$root/holds/$agent-$sid"
    event() { : > "$root/events/$(date +%s)$$-$agent-$1"; }
    # The agent process that owns this hold (skip an intermediate sh -c), so the
    # app can drop the hold if the agent is killed without running its Stop hook,
    # and keep it while the agent's process tree is busy.
    create() {
      owner="$PPID"
      case "$(basename "$(ps -o comm= -p "$owner" 2>/dev/null)" 2>/dev/null)" in
        sh|bash|zsh|dash|-sh|-bash|-zsh) owner=$(ps -o ppid= -p "$owner" 2>/dev/null | tr -d ' ') ;;
      esac
      case "$owner" in ''|*[!0-9]*|0|1) owner=0 ;; esac
      printf '{"agent":"%s","started":%s,"expires":0,"pid":%s}\n' "$agent" "$(date +%s)" "$owner" > "$root/holds/.$agent-$sid.tmp" && mv -f "$root/holds/.$agent-$sid.tmp" "$hold"
    }
    case "$action" in
      start) create ;;
      touch) if [ -f "$hold" ]; then touch "$hold"; else create; fi ;;
      stop)  [ -f "$hold" ] && { rm -f "$hold"; event done; } ;;
      wait)  [ -f "$hold" ] && event waiting ;;
      end)   rm -f "$hold" ;;
    esac
    exit 0
    """#

    /// User-facing CLI: afkpug hold | release | run | status
    static let cli = #"""
    #!/bin/sh
    # AFK Pug CLI
    dir="$HOME/.afkpug/holds"; mkdir -p "$dir"
    secs() { case "$1" in *h) echo $(( ${1%h} * 3600 ));; *m) echo $(( ${1%m} * 60 ));; *s) echo "${1%s}";; *) echo "$1";; esac; }
    case "$1" in
      hold)
        shift; dur=1800; reason="manual"
        while [ $# -gt 0 ]; do
          case "$1" in
            --for) dur=$(secs "$2"); shift 2 ;;
            --reason) reason=$(printf '%s' "$2" | tr -d '"\\\000-\037'); shift 2 ;;
            *) shift ;;
          esac
        done
        now=$(date +%s); id="cli-$now-$$"
        printf '{"agent":"cli","started":%s,"expires":%s,"reason":"%s"}\n' "$now" $((now + dur)) "$reason" > "$dir/$id"
        echo "AFK Pug holding for $((dur / 60))m  (id: $id)" ;;
      release)
        if [ -n "$2" ]; then rm -f "$dir/$2"; else rm -f "$dir"/cli-*; fi
        echo "Released." ;;
      run)
        shift; [ "$1" = "--" ] && shift
        [ $# -eq 0 ] && { echo "usage: afkpug run -- <command>"; exit 2; }
        id="run-$(date +%s)-$$"
        printf '{"agent":"%s","started":%s,"expires":0,"reason":"run","pid":%s}\n' "$(basename "$1")" "$(date +%s)" "$$" > "$dir/$id"
        # Keep-alive must not hold the caller's stdout/stderr open (out=$(afkpug run ...)).
        ( while kill -0 $$ 2>/dev/null; do sleep 60; [ -f "$dir/$id" ] && touch "$dir/$id"; done ) </dev/null >/dev/null 2>&1 &
        keepalive=$!
        trap 'kill "$keepalive" 2>/dev/null; rm -f "$dir/$id"' EXIT
        trap 'exit 130' INT; trap 'exit 143' TERM
        "$@" ;;
      status)
        n=$(ls "$dir" 2>/dev/null | wc -l | tr -d ' ')
        echo "Active holds: $n"; ls "$dir" 2>/dev/null | sed 's/^/  - /' ;;
      *)
        cat <<EOF
    AFK Pug - keep your Mac awake while you're away
      afkpug hold [--for 30m|2h] [--reason text]   keep awake for a while
      afkpug release [id]                          drop a hold (all CLI holds if no id)
      afkpug run -- <command>                      keep awake while a command runs
      afkpug status                                list active holds
    EOF
        ;;
    esac
    """#

    /// Run by launchd every 30 s: if AFK Pug is gone, undo everything it left behind.
    /// `pgrep -x AFKPug` alone is wrong: `AFKPug --mcp` servers share the name.
    /// Match the app bundle's executable (the `\.` keeps grep from matching itself).
    static let watchdog = #"""
    #!/bin/sh
    state="$HOME/.afkpug/state"
    /bin/ps -Ao args= | /usr/bin/grep -E 'AFK Pug\.app/Contents/MacOS/AFKPug( |$)' | /usr/bin/grep -vq -- '--mcp' && exit 0
    if [ -f "$state/paused-pids" ]; then
      xargs kill -CONT < "$state/paused-pids" 2>/dev/null; rm -f "$state/paused-pids"
    fi
    if [ -f "$state/lid-override" ]; then
      /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 && rm -f "$state/lid-override"
    fi
    if [ -f "$state/lowpower-restore" ]; then
      # The file names the power source we changed: b (battery) or c (charger).
      case "$(cat "$state/lowpower-restore" 2>/dev/null)" in
        b) /usr/bin/sudo -n /usr/bin/pmset -b lowpowermode 0 ;;
        c) /usr/bin/sudo -n /usr/bin/pmset -c lowpowermode 0 ;;
      esac
      rm -f "$state/lowpower-restore"
    fi
    if [ -f "$state/mute-restore" ]; then
      /usr/bin/osascript -e 'set volume output muted false' >/dev/null 2>&1; rm -f "$state/mute-restore"
    fi
    exit 0
    """#
}
