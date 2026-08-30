---
description: Resume vault hooks after /vault-pause
---

Run this shell command to clear the pause flag for the current working directory, then confirm to the user that vault hooks are active again:

```bash
h=$(printf '%s' "$PWD" | md5sum | cut -c1-12)
rm -f "/tmp/vault-pause-${h}"
echo "Vault resumed for workspace $PWD. Hooks are active: injection at SessionStart, capture sweeps on Stop whenever the last sweep is older than 30 minutes."
```
