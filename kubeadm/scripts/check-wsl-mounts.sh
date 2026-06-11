#!/bin/bash
while IFS= read -r line; do
  nf=$(echo "$line" | awk '{print NF}')
  if [[ "$nf" != "6" ]]; then
    echo "$nf $line"
  fi
done < /proc/mounts
