# Testing

```bash
pip install -e '.[test]'
pytest -q
```

The suite runs in about 20 seconds and touches no network. Kiosks are folders standing in for their C: drives (`kfw.demo`), with a thread playing their launchers and watchdog: it takes control files, answers screenshots, stores `password.seed`, and acknowledges messages. It covers:

- **The web app** (`tests/test_web.py`): signing in, lockout, CSRF and origin checks, first-admin setup, roles (an operator is refused every admin action, and each refusal is audited), the fleet served to the page, every kiosk action, the config editor (existing and new kiosks, one launcher per screen), the password hand-over (never in the audit log or the database), messages, restarts, busy kiosks, the deploy command builder (refusing names with code in them), accounts (must-change, role changes and disabling taking effect at once, the last admin kept), importing PowerShell accounts, kiosk-list upload, and the audit log's search and CSV export.
- **The collector** (`tests/test_collector.py`): reboot reconciliation (one boot is one reboot, failed triggers, unexplained boots, unexpected shutdowns), a whole scan of fake kiosks (statuses, the ledger with copied Windows events, a row mid-append, the status file, the CSV's exact format, a second scan adding nothing, a kiosk going stale), a CSV saved from Excel left alone, the published copy restored from the local one, .xlsx/.txt kiosk lists, and a scan started and stopped from the page.

## Over real SMB

`tests/test_smb.py` runs a scan and every kiosk action over SMB, against Samba with one share per kiosk. It is skipped unless `KFW_TEST_SMB` is set:

```bash
sudo apt-get install samba
sudo useradd -M kfwsmb && (echo 'Kiosk-Admin-1!'; echo 'Kiosk-Admin-1!') | sudo smbpasswd -s -a kfwsmb
sudo mkdir -p /srv/kiosks/MWEB1 /srv/kiosks/PWEB1 && sudo chown -R "$USER" /srv/kiosks
cat <<'CONF' | sudo tee /etc/samba/smb.conf
[global]
  server role = standalone server
  server min protocol = SMB2
[MWEB1]
  path = /srv/kiosks/MWEB1
  read only = no
  valid users = kfwsmb
  force user = kfwsmb
[PWEB1]
  path = /srv/kiosks/PWEB1
  read only = no
  valid users = kfwsmb
  force user = kfwsmb
CONF
echo '127.0.0.1 MWEB1 PWEB1' | sudo tee -a /etc/hosts
sudo systemctl restart smbd

KFW_TEST_SMB='\\localhost\{0}|kfwsmb|Kiosk-Admin-1!|/srv/kiosks' pytest -q tests/test_smb.py
```

Restarts go over WMI/DCOM to Windows, so no Samba test covers them. Try **Restart...** on one kiosk with a countdown first.

## The page in a browser

```bash
KFW_DATA_DIR=./data kfw serve --demo --port 8080
```

Open the setup link from the log, make an admin, and use the pretend fleet.
