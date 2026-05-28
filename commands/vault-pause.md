---
description: Pause vault hooks for this session (sensitive or throwaway work)
---

Run this shell command to write the pause flag for the current session, then confirm to the user that vault hooks are now disabled until /vault-resume:

```bash
SID="${CLAUDE_SESSION_ID:-default}"
mkdir -p "/tmp/vault-${SID}"
touch "/tmp/vault-${SID}/paused"
echo "Vault paused for session ${SID}. All vault hooks will no-op until /vault-resume."
```
