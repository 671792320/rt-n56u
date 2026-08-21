#!/bin/sh
# Start the Q7 LAN discovery watcher once.
PIDFILE=/var/run/q7-lanwatch.pid

if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
    rm -f "$PIDFILE"
fi

/usr/bin/lanwatch >/tmp/q7-lanwatch.log 2>&1 &
echo $! >"$PIDFILE"
