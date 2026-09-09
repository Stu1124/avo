#!/bin/zsh
# Fires a series of prompts at the running Avo and prints the tool calls + replies from the log.
LOG="$HOME/Library/Application Support/Avo/avo.log"
ask() { open "avo://ask?text=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"; sleep "${2:-12}"; }
mark=$(wc -l < "$LOG")
ask "What time is it and what app am I looking at?" 10
ask "List my reminders" 12
ask "Find recent files on my desktop" 12
ask "What's on my calendar tomorrow?" 12
ask "Any unread emails?" 12
ask "Show my recent texts" 12
ask "Remember that my favorite tea is Earl Grey" 10
tail -n +$((mark+1)) "$LOG" | grep -E 'Turn start|Tool call|Turn done|ERR' 
