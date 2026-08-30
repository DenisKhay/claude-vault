---
description: Pause vault hooks for this workspace (sensitive or throwaway work)
---

Run this shell command to write the pause flag for the current working directory, then report the result to the user — including, in your own words, what it costs (below):

```bash
h=$(printf '%s' "$PWD" | md5sum | cut -c1-12)
touch "/tmp/vault-pause-${h}"
echo "Vault paused for workspace $PWD (flag /tmp/vault-pause-${h})."
```

**Tell the user what is now off**, so a pause is never a silent trade:

- No context is injected at session start here.
- No capture sweep runs, so nothing learned in this workspace reaches the vault.
- **No crash-recovery pointer is spooled either** — if a paused session is killed, nothing will later point at its transcript. That is intended for sensitive work (a spool record would send a future session to mine it), but it means an abandoned pause loses knowledge silently.

**It does not expire.** That is deliberate: auto-resuming would restart capture inside the sensitive work the pause was switched on for, and sweeps auto-push, so the leak would reach a remote within seconds. Instead every session start in this directory prints a PAUSED banner with the pause's age, and escalates the wording past a day. Lift it with `/vault-resume`.

The flag is keyed by working directory, not session: slash-command shells do not know the session id, hooks do know their cwd, and the cwd is the one key both sides share. Other sessions in the SAME directory are paused too; other directories are unaffected. The flag lives in `/tmp`, so a reboot lifts it.
