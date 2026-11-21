#!/bin/bash
# DEV/TEST ONLY: samples the File Provider extension's RSS (KiB) every 50 ms
# until killed; prints the peak. Simulator numbers are indicative only.
peak=0; while true; do
  r=$(ps -axo rss=,comm= | awk '/PsyFileProvider$/ {print $1}' | sort -n | tail -1)
  [ -n "$r" ] && [ "$r" -gt "$peak" ] && { peak=$r; echo "$(date +%T.%N | cut -c1-12) peak_kib=$peak" >> "$1"; }
  sleep 0.05
done
