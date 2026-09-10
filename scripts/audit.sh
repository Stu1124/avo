#!/bin/zsh
# Live audit: fires read-only requests through the running app, one every 14 s, then prints the outcome table.
LOG="$HOME/Library/Application Support/Avo/avo.log"
ask() { open "avo://ask?text=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"; sleep ${2:-14}; }
START=$(date -u +%Y-%m-%dT%H:%M:%S)
ask "What time is it and what app am I looking at?" 8
ask "List my reminder lists"
ask "What's on my calendar tomorrow?"
ask "Any unread emails?"
ask "Show my recent texts"
ask "Find PDFs in my Documents folder modified this year"
ask "List my Apple Notes folders"
ask "Search the web for the current Fed funds rate" 18
ask "What is scheduled?"
ask "What do you remember about my preferences?"
ask "Draft a reply saying I can do Thursday at 3" 
ask "Make a prompt asking an AI to explain the Monty Hall problem briefly"
ask "Which coding tasks are running?"
ask "List my external coding sessions"
ask "Remind me to stretch in 1 minute"
ask "List MCP servers"
ask "What's playing on Spotify?"
ask "Search my Drive for notes"
ask "Find free 30 minute slots tomorrow afternoon"
sleep 50
echo "=== TURNS since $START"
awk -v s="$START" '$1 >= s' "$LOG" | grep -E 'Turn start|Tool call|Tool .*→|Turn done|ERR|WARN' | cut -c12-210
