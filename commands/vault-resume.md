---
description: Resume vault hooks after /vault-pause
---

Run this shell command to clear the pause flag for the current working directory, then confirm to the user that vault hooks are active again:

```bash
h=$(printf '%s' "$PWD" | md5sum | cut -c1-12)
f="/tmp/vault-pause-${h}"
if [[ -f "$f" ]]; then
  age=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 3600 ))
  rm -f "$f"
  echo "Vault resumed for workspace $PWD (had been paused ${age}h)."
else
  echo "Vault was not paused for workspace $PWD — nothing to resume."
fi
```

If it had been paused for more than a few hours, say so plainly and offer to sweep: everything learned in this workspace during the pause was never captured, and it is recoverable only from the transcripts, which the host deletes on its own retention timer. Hooks are active again — injection at SessionStart, capture sweeps on Stop whenever the last sweep is older than 30 minutes.
