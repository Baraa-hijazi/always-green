# always-green

Keeps Microsoft Teams (web) active on a droplet during scheduled hours and reports status to Telegram.

How it works: Chrome runs Teams on a virtual display (Xvfb). During the schedule a script nudges the mouse every 60-90s, checks the page through Chrome's DevTools endpoint (detects crashes and sign-outs), and sends screenshots to Telegram. Outside the schedule the browser is closed, so you show Offline.

## 1. Telegram bot
In Telegram, message @BotFather, `/newbot`, copy the token.

## 2. Droplet
Ubuntu 24.04, Basic Regular 2 GB or more, SSH key auth. Under "Startup scripts", paste the contents of `userdata.sh` with your bot token filled in. Create.

The droplet installs everything itself (about 5 minutes; log at `/var/log/always-green-setup.log`).

## 3. Link Telegram
Send the bot any message. The first chat that writes to it is linked; others are ignored.

Manual alternative to the startup script: copy the repo to the droplet, `cp config.env.example config.env`, fill in the token, `./setup.sh`. After editing any file, run `./make-userdata.sh` to regenerate `userdata.sh`.

## 4. Log in to Teams (once, before the first scheduled day)
```bash
# on the droplet
systemctl start ag-vnc ag-browser
cat /root/vnc-password
# on your machine (5901 locally: macOS Screen Sharing treats localhost:5900 as itself)
ssh -N -L 5901:localhost:5900 root@DROPLET
```
Open `vnc://127.0.0.1:5901` (macOS: Finder > Go > Connect to Server) with that password. Clipboard paste does not reach the droplet, so type your email and password. Sign in, complete MFA, choose "Stay signed in". Then:
```bash
systemctl stop ag-browser ag-vnc
```

## 5. Dry run
```bash
systemctl start ag-session.target     # or /on in Telegram
journalctl -u ag-keepalive -f         # first screenshot arrives after ~2 min
systemctl stop ag-session.target      # or /off
```
Check in the screenshot that your status is green, and from another account or your phone after 10+ minutes.

## Telegram commands
- `/status`: screenshot and page state (or next start time when inactive)
- `/on`, `/off`: start or stop the session manually

Alerts are sent automatically when the browser dies or Teams lands on a login page.

## Notes
- Teams reopens the last chat on load, so the keepalive switches it to Calendar (Ctrl+Shift+3) before the first screenshot; otherwise incoming chats could get marked as read.
- Change the schedule in `config.env` and re-run `./setup.sh`. Check with `systemctl list-timers 'ag-*'`.
- If the nudge interval needs tuning, edit `NUDGE_MIN_SEC` / `NUDGE_MAX_SEC`.

## Teardown
1. Sign out of Teams over VNC, or revoke sessions at https://mysignins.microsoft.com.
2. Destroy the droplet (a powered-off droplet is still billed).
3. Revoke the bot token in @BotFather if you won't reuse it.
