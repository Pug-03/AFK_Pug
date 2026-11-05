/// Shell scripts AFK Pug writes to ~/.afkpug/bin.
enum Scripts {
    /// Called by agent hooks: afkpug-hook start|stop|wait|end <agent>  (hook JSON on stdin)
    static let hook = #"""
    #!/bin/sh
    # AFK Pug agent hook. Usage: afkpug-hook start|stop|wait|end <agent>
    action="$1"; agent="${2:-agent}"
    input=$(cat 2>/dev/null)
    sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -z "$sid" ] && sid="$PPID"
    root="$HOME/.afkpug"; mkdir -p "$root/holds" "$root/events"
    hold="$root/holds/$agent-$sid"
    event() { : > "$root/events/$(date +%s)$$-$agent-$1"; }
    case "$action" in
      start) printf '{"agent":"%s","started":%s,"expires":0}\n' "$agent" "$(date +%s)" > "$hold" ;;
      stop)  [ -f "$hold" ] && { rm -f "$hold"; event done; } ;;
      wait)  [ -f "$hold" ] && { rm -f "$hold"; event waiting; } ;;
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
            --reason) reason=$(printf '%s' "$2" | tr -d '"\\'); shift 2 ;;
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
        printf '{"agent":"%s","started":%s,"expires":0,"reason":"run"}\n' "$(basename "$1")" "$(date +%s)" > "$dir/$id"
        ( while kill -0 $$ 2>/dev/null; do sleep 60; [ -f "$dir/$id" ] && touch "$dir/$id"; done ) &
        trap 'rm -f "$dir/$id"' EXIT INT TERM
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

    /// Run by launchd every 30 s: if AFK Pug is gone but left the lid override on, undo it.
    static let watchdog = #"""
    #!/bin/sh
    flag="$HOME/.afkpug/state/lid-override"
    paused="$HOME/.afkpug/state/paused-pids"
    if [ -f "$paused" ] && ! /usr/bin/pgrep -x AFKPug >/dev/null 2>&1; then
      xargs kill -CONT < "$paused" 2>/dev/null; rm -f "$paused"
    fi
    [ -f "$flag" ] || exit 0
    if ! /usr/bin/pgrep -x AFKPug >/dev/null 2>&1; then
      /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 && rm -f "$flag"
      lp="$HOME/.afkpug/state/lowpower-restore"
      if [ -f "$lp" ]; then /usr/bin/sudo -n /usr/bin/pmset -a lowpowermode 0; rm -f "$lp"; fi
    fi
    """#
}
