# always-green

Keeps Microsoft Teams (web) active on a droplet during scheduled hours and reports status to Telegram.

How it works: Chrome runs Teams on a virtual display (Xvfb). During the schedule a script nudges the mouse every 60-90s, checks the page through Chrome's DevTools endpoint (detects crashes and sign-outs), and sends screenshots to Telegram. Outside the schedule the browser is closed, so you show Offline.

## 1. Telegram bot
1. In Telegram, message @BotFather, `/newbot`, copy the token.
2. Leave `TELEGRAM_CHAT_ID` empty for now; the bot tells you your id in step 3.

## 2. Droplet
Ubuntu 24.04, Basic, 2 vCPU / 4 GB, SSH key auth.

```bash
scp -r always-green root@DROPLET:/root/      # or git clone
ssh root@DROPLET
cd always-green
cp config.env.example config.env && nano config.env   # token, schedule
./setup.sh
```

## 3. Chat id
Send the bot any message. It replies with your chat id. Put it in `config.env`, run `./setup.sh` again, send `/status` to confirm.

## 4. Log in to Teams (once, before the first scheduled day)
```bash
# on the droplet
systemctl start ag-vnc ag-browser
# on your machine
ssh -L 5900:localhost:5900 root@DROPLET
```
Open a VNC viewer at `localhost:5900`, sign in, complete MFA, choose "Stay signed in". Then:
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
- Leave Teams on the Calendar or Activity tab, otherwise incoming chats get marked as read.
- Change the schedule in `config.env` and re-run `./setup.sh`. Check with `systemctl list-timers 'ag-*'`.
- If the nudge interval needs tuning, edit `NUDGE_MIN_SEC` / `NUDGE_MAX_SEC`.

## Teardown
1. Sign out of Teams over VNC, or revoke sessions at https://mysignins.microsoft.com.
2. Destroy the droplet (a powered-off droplet is still billed).
3. Revoke the bot token in @BotFather if you won't reuse it.
