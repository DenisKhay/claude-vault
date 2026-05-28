---
description: Resume vault hooks after /vault-pause
---

Run this shell command to clear the pause flag for the current session, then confirm to the user that vault hooks are active again:

```bash
SID="${CLAUDE_SESSION_ID:-default}"
rm -f "/tmp/vault-${SID}/paused"
echo "Vault resumed for session ${SID}. Hooks are active. Next Stop, PreCompact, or 25th tool call will trigger actualize."
```
