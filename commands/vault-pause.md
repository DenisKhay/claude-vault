---
description: Pause vault hooks for this workspace (sensitive or throwaway work)
---

Run this shell command to write the pause flag for the current working directory, then confirm to the user that vault hooks are now disabled here until /vault-resume:

```bash
h=$(printf '%s' "$PWD" | md5sum | cut -c1-12)
touch "/tmp/vault-pause-${h}"
echo "Vault paused for workspace $PWD (flag /tmp/vault-pause-${h}). Injection and capture hooks no-op for every session in this directory until /vault-resume."
```

Note: the flag is keyed by working directory (slash-command shells don't know the session id, hooks do know their cwd — the cwd is the one key both sides share). Other sessions in the SAME directory are paused too; sessions in other directories are unaffected.
