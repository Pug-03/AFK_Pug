/// Shell scripts AFK Pug writes to ~/.afkpug/bin.
enum Scripts {
    /// Called by agent hooks: afkpug-hook <action> <agent>  (hook JSON on stdin)
    ///   start  prompt submitted (UserPromptSubmit, BeforeAgent, beforeSubmitPrompt): create the hold
    ///   touch  tool calls: re-arm the hold (recreate it if missing or if it is a usage-limit hold).
    ///          Within 60 s of stop/end only a pre-tool event (new work) recreates it, so late
    ///          post-tool events (Cursor) can't resurrect a finished turn; an interrupt never does.
    ///   stop   turn end (Stop, AfterAgent, Cursor stop): drop the hold, "done" event
    ///          (Cursor: status "aborted" = end, "error" = fail). Background tasks still
    ///          running: the hold is kept and marked "bg".
    ///   notify Claude Notification: by notification_type
    ///   wait   permission prompt (Gemini Notification, Codex PermissionRequest): "waiting" event, hold kept
    ///   fail   Claude StopFailure: drop the hold, "failed" event; a usage limit with a reset
    ///          time keeps an expiring hold until then (so Claude can continue on its own)
    ///   end    session end / interrupt: drop the hold
    /// Session id: session_id (Claude, Gemini, Codex) or conversation_id (Cursor); without
    /// one, the agent's pid. Events are named <time><pid>-<agent>-<kind>@<session>.
    /// Dropping a hold is a claim (atomic rename), so parallel hooks report it once.
    static let hook = #"""
    #!/bin/sh
    # AFK Pug agent hook. Usage: afkpug-hook start|touch|stop|notify|wait|fail|end <agent>
    # Always exits 0 and prints nothing (stdout of UserPromptSubmit becomes context).
    action="$1"; agent="${2:-agent}"
    input=$(head -c 65536 2>/dev/null)
    # First match of a string key (tool_input can contain another one). Escaped quotes
    # inside the value (\") don't end it; they come back as plain quotes.
    field() {
      printf '%s' "$input" | LC_ALL=C grep -oE '"'"$1"'"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1 |
        LC_ALL=C sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//; s/\\"/"/g'
    }
    # Cursor also runs Claude Code's hooks from ~/.claude/settings.json: count those as
    # Cursor, or leave it to Cursor's own hooks when those are connected too.
    if [ "$agent" = claude ]; then
      case "$input" in *'"cursor_version"'*)
        LC_ALL=C grep -q 'afkpug-hook' "$HOME/.cursor/hooks.json" 2>/dev/null && exit 0
        agent=cursor ;;
      esac
    fi
    # The agent process that owns this hold (skip an intermediate sh -c), so the
    # app can drop the hold if the agent is killed without running its Stop hook,
    # and keep it while the agent's process tree is busy.
    owner="$PPID"
    case "$(basename "$(ps -o comm= -p "$owner" 2>/dev/null)" 2>/dev/null)" in
      sh|bash|zsh|dash|-sh|-bash|-zsh) owner=$(ps -o ppid= -p "$owner" 2>/dev/null | tr -d ' ') ;;
    esac
    case "$owner" in ''|*[!0-9]*|0|1) owner=0 ;; esac
    case "$agent" in cursor) sid=$(field conversation_id); [ -z "$sid" ] && sid=$(field session_id) ;;
      *) sid=$(field session_id); [ -z "$sid" ] && sid=$(field conversation_id) ;; esac
    sid=$(printf '%s' "$sid" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c 1-80)
    # No session id: one hold per agent process (not per throwaway hook shell).
    if [ -z "$sid" ]; then if [ "$owner" -gt 1 ]; then sid="p$owner"; else sid="p$PPID"; fi; fi
    agent=$(printf '%s' "$agent" | LC_ALL=C tr -c 'A-Za-z0-9_' '_' | cut -c 1-40)
    root="$HOME/.afkpug"; mkdir -p "$root/holds" "$root/events" 2>/dev/null
    hold="$root/holds/$agent-$sid"
    ended="$root/holds/.ended-$agent-$sid"
    now=$(date +%s)
    event() { : > "$root/events/$now$$-$agent-$1@$sid"; }
    # What the agent is doing, for the app's list. Values stay JSON-escaped, so the files
    # are valid JSON. Private to this user, and nothing here leaves the Mac.
    tasks="$root/tasks"; task="$tasks/$agent-$sid"
    raw() {
      printf '%s' "$input" | LC_ALL=C grep -oE '"'"$1"'"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1 |
        LC_ALL=C sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//'
    }
    # save_task [prompt]: the folder, and the prompt only when this event is the prompt
    # (a tool's input can have a "prompt" of its own).
    save_task() {
      cwd=$(raw cwd)
      [ -z "$cwd" ] && cwd=$(printf '%s' "$input" | LC_ALL=C grep -oE '"workspace_roots"[[:space:]]*:[[:space:]]*\[[[:space:]]*"([^"\\]|\\.)*"' | head -n 1 | LC_ALL=C sed -E 's/.*\[[[:space:]]*"//; s/"$//')
      p=""; [ "$1" = prompt ] && p=$(raw prompt)
      (umask 077; mkdir -p "$tasks" && printf '{"cwd":"%s","prompt":"%s"}\n' "$cwd" "$p" > "$task.$$.tmp" && mv -f "$task.$$.tmp" "$task") 2>/dev/null
      rm -f "$task.now"
    }
    write_now() { (umask 077; mkdir -p "$tasks" && printf '%s\n' "$1" > "$task.$$.tmp.now" && mv -f "$task.$$.tmp.now" "$task.now") 2>/dev/null; }
    save_now() {
      [ -f "$task" ] || save_task
      tool=$(raw tool_name); [ -z "$tool" ] && return
      target=$(raw file_path); [ -z "$target" ] && target=$(raw path)
      # A command's first two words only: the rest can hold secrets. A space can't split an escape.
      [ -z "$target" ] && target=$(raw command | LC_ALL=C sed -E 's/^[[:space:]]*([^[:space:]]+([[:space:]]+[^[:space:]]+)?).*/\1/')
      write_now "{\"tool\":\"$tool\",\"target\":\"$target\"}"
    }
    drop_task() { rm -f "$task" "$task.now"; }
    # Kept for the app's "finished" list; it deletes them, or they age out after an hour.
    keep_task() { [ -f "$task" ] && touch "$task"; }
    # create [expires] [reason]
    create() {
      rm -f "$ended"
      extra=""; [ -n "$2" ] && extra=",\"reason\":\"$2\""
      tmp="$root/holds/.$agent-$sid.$$.tmp"
      printf '{"agent":"%s","started":%s,"expires":%s,"pid":%s%s}\n' "$agent" "$now" "${1:-0}" "$owner" "$extra" > "$tmp" && mv -f "$tmp" "$hold"
    }
    # Atomically takes the hold away; true only for the one caller that got it.
    claim() {
      c="$root/holds/.claim-$agent-$sid.$$"
      mv "$hold" "$c" 2>/dev/null && { rm -f "$c"; return 0; }
      return 1
    }
    # The turn is over: late tool events must not bring the hold back for 60 s.
    mark_ended() { : > "$ended" 2>/dev/null; }
    recently_ended() {
      [ -f "$ended" ] || return 1
      t=$(stat -f %m "$ended" 2>/dev/null) || return 1
      [ $((now - t)) -lt 60 ] && [ $((now - t)) -ge -5 ] && return 0
      rm -f "$ended"; return 1
    }
    # Epoch of the reset in a usage-limit message, empty if none can be read:
    #   "resets 3:45pm", "resets 3pm", "4.30pm", "3 p.m.", "resets Mon 12:00am",
    #   "resets Nov 8, 9am", "Nov 8 at 9am", "will reset at 3pm (America/New_York)",
    #   "resets 2026-08-09 00:00 UTC", "2026-08-09T00:00:00.000Z", "...+0700",
    #   "resets in 2 hours", "Claude AI usage limit reached|<epoch>".
    # A clock time up to 60 min ago is today (shown rounded, or a late hook), not tomorrow.
    reset_at() {
      e=$(printf '%s' "$1" | LC_ALL=C sed -nE 's/.*usage limit reached\|([0-9]{9,11}).*/\1/p' | head -n 1)
      [ -n "$e" ] && { echo "$e"; return; }
      tz=$(printf '%s' "$1" | LC_ALL=C grep -oE '\([A-Za-z_]+(/[A-Za-z0-9_+-]+)+\)' | head -n 1 | tr -d '()')
      [ -n "$tz" ] && [ ! -f "/usr/share/zoneinfo/$tz" ] && tz=""
      r=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C sed -nE 's/.*(^|[^a-z])resets?[[:space:]]+//p' | head -n 1 |
        LC_ALL=C sed -E 's/\([^)]*\)//g; s/^(at|on)[[:space:]]+//' | cut -c 1-60)
      [ -z "$r" ] && return
      d() { if [ -n "$tz" ]; then TZ="$tz" date "$@"; else date "$@"; fi; }
      at_day() { d -j -f '%Y-%m-%d %H:%M:%S' "$1 $h:$m:00" +%s 2>/dev/null; }
      # in N hours / minutes
      rel=$(printf '%s' "$r" | LC_ALL=C sed -nE 's/^in[[:space:]]+([0-9]{1,4})[[:space:]]*(h|hr|hrs|hours?|m|mins?|minutes?)([^a-z].*|$)/\1 \2/p')
      if [ -n "$rel" ]; then
        set -- $rel; n=$(expr "$1" + 0)
        case "$2" in h*) echo $((now + n * 3600)) ;; *) echo $((now + n * 60)) ;; esac
        return
      fi
      # ISO / numeric date: 2026-08-09 00:00[:00][.000][z|utc|gmt|+0700|+07:00]
      iso=$(printf '%s' "$r" | LC_ALL=C sed -nE 's/^([0-9]{4}-[0-9]{2}-[0-9]{2})[ t]([0-9]{1,2}):([0-9]{2})(:([0-9]{2}))?(\.[0-9]*)?[[:space:]]*(z|utc|gmt|[+-][0-9]{2}:?[0-9]{2})?.*/\1 \2 \3 x\5 x\7/p')
      if [ -n "$iso" ]; then
        set -- $iso; day="$1"; h=$(expr "$2" + 0); m=$(expr "$3" + 0); sec="${4#x}"; zone="${5#x}"
        [ -z "$sec" ] && sec=0
        case "$zone" in
          z|utc|gmt) TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$day $h:$m:$sec" +%s 2>/dev/null ;;
          [+-]*)
            off=$(printf '%s' "$zone" | tr -d ':+-'); oh=$(expr "$(printf '%s' "$off" | cut -c 1-2)" + 0); om=$(expr "$(printf '%s' "$off" | cut -c 3-4)" + 0)
            t=$(TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$day $h:$m:$sec" +%s 2>/dev/null) || return
            case "$zone" in +*) echo $((t - oh * 3600 - om * 60)) ;; *) echo $((t + oh * 3600 + om * 60)) ;; esac ;;
          *) d -j -f '%Y-%m-%d %H:%M:%S' "$day $h:$m:$sec" +%s 2>/dev/null ;;
        esac
        return
      fi
      wd=$(printf '%s' "$r" | LC_ALL=C sed -nE 's/^(mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?[[:space:]]+.*/\1/p')
      [ -n "$wd" ] && r=$(printf '%s' "$r" | LC_ALL=C sed -E 's/^[a-z]+\.?,?[[:space:]]+//')
      # Month and day: "nov 8, 9am", "nov 8 at 9am", "november 8th, 2026 9:00am", "nov 8"
      md=$(printf '%s' "$r" | LC_ALL=C sed -nE 's/^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?[[:space:]]+([0-9]{1,2})(st|nd|rd|th)?(,?[[:space:]]+([0-9]{4}))?([^0-9].*|$)/\1 \2 x\5/p')
      mon=""; yr=""
      if [ -n "$md" ]; then
        set -- $md; dd=$(expr "$2" + 0); yr="${3#x}"
        i=1; for mm in jan feb mar apr may jun jul aug sep oct nov dec; do [ "$mm" = "$1" ] && break; i=$((i + 1)); done
        mon="$i"
        r=$(printf '%s' "$r" | LC_ALL=C sed -E 's/^[a-z]+\.?[[:space:]]+[0-9]{1,2}(st|nd|rd|th)?(,?[[:space:]]+[0-9]{4})?,?[[:space:]]*//; s/^at[[:space:]]+//')
      fi
      # Clock time: 9am, 9:05pm, 4.30pm, 3 p.m., 15:00, 12:00am
      t=$(printf '%s' "$r" | LC_ALL=C sed -nE 's/^([0-9]{1,2})([:.]([0-9]{2}))?[[:space:]]*(([ap])\.?[[:space:]]?m\.?)?([^0-9a-z].*|$)/\1 x\3 x\5/p')
      if [ -z "$t" ]; then
        [ -n "$mon" ] && [ -z "$r" ] && t="0 x x"   # "resets nov 8": midnight
        [ -z "$t" ] && return
      fi
      set -- $t
      h=$(expr "$1" + 0); m="${2#x}"; ap="${3#x}"
      [ -z "$m" ] && m=0; m=$(expr "$m" + 0)
      case "$ap" in a) [ "$h" -eq 12 ] && h=0 ;; p) [ "$h" -lt 12 ] && h=$((h + 12)) ;; esac
      { [ "$h" -gt 23 ] || [ "$m" -gt 59 ]; } && return
      if [ -n "$mon" ]; then
        y="$yr"; [ -z "$y" ] && y=$(d +%Y)
        at=$(at_day "$y-$mon-$dd") || return
        # No year given and long past: next year's date.
        [ -z "$yr" ] && [ "$at" -lt $((now - 3600)) ] && { at=$(at_day "$((y + 1))-$mon-$dd") || return; }
        echo "$at"; return
      fi
      n=0
      if [ -n "$wd" ]; then
        i=1; for w in mon tue wed thu fri sat sun; do [ "$w" = "$wd" ] && break; i=$((i + 1)); done
        n=$(( (i - $(d +%u) + 7) % 7 ))
      fi
      # Calendar days, not 86400 s steps: right across a DST change.
      at=$(at_day "$(d -j -v+${n}d +%Y-%m-%d)") || return
      if [ "$at" -lt $((now - 3600)) ]; then
        if [ -n "$wd" ]; then n=$((n + 7)); else n=$((n + 1)); fi
        at=$(at_day "$(d -j -v+${n}d +%Y-%m-%d)") || return
      fi
      echo "$at"
    }
    case "$action" in
      start) save_task prompt; create ;;
      touch)
        # postToolUseFailure from an interrupt: the user stopped the agent.
        printf '%s' "$input" | LC_ALL=C grep -Eq '"is_interrupt"[[:space:]]*:[[:space:]]*true' && exit 0
        # A usage-limit hold (fixed expiry) turns back into a normal one when work resumes.
        if [ -f "$hold" ] && LC_ALL=C grep -q '"expires":0,' "$hold"; then save_now; touch "$hold"; exit 0; fi
        if recently_ended; then
          case "$(field hook_event_name)" in PreToolUse|BeforeTool|preToolUse) ;; *) exit 0 ;; esac
        fi
        save_now; create ;;
      stop)
        [ "$agent" = cursor ] && case "$(field status)" in
          aborted) rm -f "$hold"; drop_task; mark_ended; exit 0 ;;            # Cursor: user stopped it
          error) claim && { keep_task; event failed; }; mark_ended; exit 0 ;;
        esac
        # Background shells / builds still running: the session isn't done. Mark the
        # hold so idle_prompt (Claude back at its prompt) doesn't drop it.
        if printf '%s' "$input" | LC_ALL=C grep -q '"background_tasks"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^][:space:]]'; then
          if [ -f "$hold" ]; then
            if LC_ALL=C grep -q '"bg":1' "$hold"; then touch "$hold"
            else
              tmp="$root/holds/.$agent-$sid.$$.tmp"
              LC_ALL=C sed 's/}[[:space:]]*$/,"bg":1}/' "$hold" > "$tmp" && mv -f "$tmp" "$hold"
            fi
          fi
        elif claim; then
          mark_ended
          keep_task
          # Another Stop hook is continuing the turn: no "finished" yet.
          printf '%s' "$input" | LC_ALL=C grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' || event done
        fi ;;
      notify)
        case "$(field notification_type)" in
          permission_prompt|elicitation_dialog|elicitation_url_dialog) [ -f "$hold" ] && { event waiting; write_now '{"waiting":1}'; } ;;
          # Back at the prompt (e.g. after Esc). Not a usage-limit wait (Claude continues
          # on its own) or background tasks: those end by expiry / the 15 min and 6 h rules.
          idle_prompt) [ -f "$hold" ] && ! LC_ALL=C grep -Eq '"expires":[1-9]|"bg":1' "$hold" && { rm -f "$hold"; drop_task; } ;;
          quota_auto_resume_fired) create ;;   # usage limit reset: Claude continues the task
          quota_auto_resume_stale|quota_auto_resume_disabled) rm -f "$hold" ;;   # not continuing
        esac ;;
      wait) [ -f "$hold" ] && { event waiting; write_now '{"waiting":1}'; } ;;
      fail)
        # StopFailure. A claude.ai usage limit: Claude Code waits and continues the
        # task after the reset, so stay awake until then (at most 6 h). A plain
        # throttle ("not your usage limit") or any other API error releases.
        until=""
        if [ "$(field error)" = rate_limit ]; then
          msg="$(field error_details) $(field last_assistant_message)"
          case "$msg" in
            *"not your usage limit"*) ;;
            *) at=$(reset_at "$msg")
               case "$at" in
                 ''|*[!0-9]*)
                   # Unreadable reset: a date days away (weekly limit) releases; no time at all waits 30 min.
                   if printf '%s' "$msg" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C grep -Eq '(^|[^a-z])resets?[[:space:]]+((at|on)[[:space:]]+)?(mon|tue|wed|thu|fri|sat|sun|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)'; then
                     until=""
                   else until=$((now + 1800)); fi ;;
                 *) if [ "$at" -lt $((now - 3600)) ]; then until=""          # long past: stale message
                    elif [ "$at" -le "$now" ]; then until=$((now + 180))      # just passed: Claude continues any moment
                    elif [ "$at" -gt $((now + 21600)) ]; then until=""        # weekly limit days away
                    else until=$((at + 120)); fi ;;                           # Claude continues shortly after
               esac ;;
          esac
        fi
        if [ -n "$until" ]; then
          create "$until" "usage limit"; event failed
        elif claim; then
          keep_task
          event failed
        fi ;;
      end) rm -f "$hold"; drop_task; mark_ended ;;
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
    # The app writes ~/.afkpug/state/app.pid at launch (any bundle name or place).
    running() {
      pid=$(/usr/bin/head -n 1 "$HOME/.afkpug/state/app.pid" 2>/dev/null)
      case "$pid" in ''|*[!0-9]*) return 1 ;; esac
      /bin/kill -0 "$pid" 2>/dev/null || return 1
      case "$(/bin/ps -o args= -p "$pid" 2>/dev/null)" in ''|*--mcp*) return 1 ;; esac
      comm=$(/bin/ps -o comm= -p "$pid" 2>/dev/null); [ "${comm##*/}" = AFKPug ]
    }
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
    /// The app writes its pid to state/app.pid at launch and removes it on quit. The pid
    /// only counts while it is alive, still an AFKPug executable (a renamed or moved
    /// bundle is fine) and not an `AFKPug --mcp` server, which shares the name.
    static let watchdog = #"""
    #!/bin/sh
    state="$HOME/.afkpug/state"
    alive() {
      pid=$(/usr/bin/head -n 1 "$state/app.pid" 2>/dev/null)
      case "$pid" in ''|*[!0-9]*) return 1 ;; esac
      /bin/kill -0 "$pid" 2>/dev/null || return 1
      case "$(/bin/ps -o args= -p "$pid" 2>/dev/null)" in ''|*--mcp*) return 1 ;; esac
      comm=$(/bin/ps -o comm= -p "$pid" 2>/dev/null)
      [ "${comm##*/}" = AFKPug ]
    }
    alive && exit 0
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
