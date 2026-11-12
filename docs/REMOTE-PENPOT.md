# A remote Penpot stack for a desktop DSH

The design stack does not need DSH on the same machine. One host runs Penpot;
a laptop runs the DSH desktop app with `dsh-penpot-plugin` pointed at it.

```
server 192.168.2.98        laptop
┌──────────────────┐       ┌──────────────────────────────┐
│ Penpot on Podman │◀──────│ DSH desktop + penpot plugin  │
│ :8090 / :8443    │  LAN  │ PENPOT_API_URL=…:8090        │
└──────────────────┘       │ PENPOT_ACCESS_TOKEN=…        │
                           └──────────────────────────────┘
```

## 1. Server: the stack alone

Clone the setup checkout (it carries `components.json`, `design/` and the
scripts) and enable the component. There is no DSH `.env`, no runtime, no
systemd unit:

```sh
git clone https://github.com/vladtsvirko/dsh-tg-docker-setup /srv/penpot
cd /srv/penpot
sudo ./setup.sh components --dir /srv/penpot --bind 192.168.2.98 enable design
```

`--bind` is the LAN address the stack publishes on (without it the default is
`127.0.0.1`). The command creates `design/.env` with generated secrets, issues
the local CA and server certificate, starts the containers, and opens
`8090`/`8443` in ufw when it is active. Data lives in `design/data/`.

- Browser UI: `https://192.168.2.98:8443/` after trusting the CA (below), or
  `http://192.168.2.98:8090/` for a quick look.
- The CA must be trusted on the **laptop**, not the server:

  ```sh
  scp <you>@192.168.2.98:/srv/penpot/design/certs/ca.crt ~/Downloads/dsh-penpot-ca.crt
  ```

  macOS: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/dsh-penpot-ca.crt`
  Windows: `certutil -addstore -f "ROOT" %USERPROFILE%\Downloads\dsh-penpot-ca.crt`
  Linux: `sudo cp ~/Downloads/dsh-penpot-ca.crt /usr/local/share/ca-certificates/dsh-penpot-ca.crt && sudo update-ca-certificates`
  Firefox: Settings → Privacy & Security → Certificates → Authorities → Import.

Create the first account, then **Settings → Access tokens → Create**. On the
HTTPS origin the Copy button works.

Check from the laptop that the API is reachable:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.2.98:8090/
```

## 2. Laptop: the plugin, pointed at the server

Install `dsh-penpot-plugin` into the desktop's DSH profile — the app's plugin
manager (add `dsh-penpot-plugin@0.4.0`, or the GitHub fallback
`github:vladtsvirko/dsh-penpot-plugin#v0.4.0`), or the CLI:

```sh
dsh plugin --profile <profile> add dsh-penpot-plugin@0.4.0
```

On DSH `0.2.1-rc.5` or newer, configure it in the UI: **Plugins** →
**dsh-penpot-plugin** → **Configure** on the `dsh-penpot` row. Set the API URL
(`http://192.168.2.98:8090`) and the token, then **Save**. The page writes the
row's config; no environment or restart is needed.

For an older DSH or a headless profile, the row falls back to the **runtime
process environment**:

```sh
export PENPOT_API_URL='http://192.168.2.98:8090'   # no /api/rpc suffix
export PENPOT_ACCESS_TOKEN='…'                      # the token from the server
```

For a desktop app launched from Finder, shell exports do not reach it. Either:

- launch the app from a terminal that has the two exports, or
- on macOS set them for the GUI session before launching:

  ```sh
  launchctl setenv PENPOT_API_URL 'http://192.168.2.98:8090'
  launchctl setenv PENPOT_ACCESS_TOKEN '…'
  ```

  and restart the app (unset with `launchctl unsetenv …` when done), or
- put the endpoint in the profile's `cordis.patch.yml` row and keep only the
  token in the environment:

  ```yaml
  - id: dsh-penpot
    config:
      apiUrl: http://192.168.2.98:8090
      token: !!js process.env.PENPOT_ACCESS_TOKEN ?? ''
  ```

Use `http://…:8090` for the plugin: it needs no CA, and the agent-side calls are
plain HTTP. The browser uses `https://…:8443` for the secure-origin Copy button.

Ask the agent for `penpot_status`: it names the endpoint and reports a missing
variable by name. `penpot_teams` proves the token.

## 3. Day two

- **Server updates:** `cd /srv/penpot && sudo ./setup.sh update` is a DSH
  update, so for a design-only host use `git pull` and
  `sudo ./setup.sh components --dir /srv/penpot --bind 192.168.2.98 enable design`
  again (it reconciles the stack and keeps `design/.env` and the data).
- **Stop / start:** `sudo ./setup.sh penpot disable` stops the
  containers and keeps data; `enable` starts them again. Neither touches DSH.
- **Token rotation:** create a new token on the server, update
  `PENPOT_ACCESS_TOKEN` on the laptop and restart the desktop app.
- **No DSH on the server:** the component command never writes a DSH `.env` and
  never restarts a runtime that is not there.
