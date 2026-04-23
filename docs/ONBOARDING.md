# SSO Onboarding

How to wire Pocket ID as the OIDC provider for Immich and Jellyfin, so members
sign in once with a passkey and get into everything.

This is a manual process today. `setup.sh` generates the shared secrets; you
paste them into each service's admin UI. A future version may automate this
via Pocket ID's API.

## 0. First things first

1. Open `https://id.${BASE_DOMAIN}/signup/setup` (the `/signup/setup` path is required for the first admin — the root URL only shows a login screen).
2. Create the first admin user. Register a passkey (biometric preferred). Use Safari for the smoothest iCloud Keychain handoff; Chrome/Edge on macOS Sonoma+ also work via the system credential picker.
3. **Sign out and sign back in with the passkey** to confirm it works before
   trusting it as the only login.

## 0.5. Create user groups

Pocket ID authorizes access to OIDC clients by group membership, so groups must exist before clients can have any authorized users. Create at minimum:

- **`members`** — the default access tier for everyone on coralstack (admin + all households). Assign this to every OIDC client users should be able to reach (Vaultwarden, Jellyfin, Ente, etc.).
- **`admins`** — elevated access for maintenance-only services (future infrastructure dashboards, etc.). Assign only to the admin user(s).

In Pocket ID: **Groups** sidebar → create both. Then **Users** → edit your admin user → add to both groups. Future household members just get added to `members` when onboarded.

Per-household groups (`household-1`, `household-2`) become relevant only when you deploy per-household service instances (per [multi-tenancy memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_multitenancy.md)). Skip for now.

## 1. Register each OIDC client in Pocket ID

In Pocket ID's admin UI, go to **OIDC Clients** → **Add Client** for each service below. You'll get back a `client_id` and `client_secret` for each — save them somewhere (you'll paste them into the service in a minute). Every client needs **Allowed groups: `members`** so authenticated users are actually authorized.

### Vaultwarden

> Requires the OIDCWarden fork (`timshel/oidcwarden` image). Mainline Vaultwarden's first-SSO-login flow is broken ([vaultwarden#6316](https://github.com/dani-garcia/vaultwarden/issues/6316)) — new users bounce back to the login form instead of being prompted for a master password. `services/vaultwarden/docker-compose.yml` pins OIDCWarden for this reason.

| Field                | Value                                                            |
| -------------------- | ---------------------------------------------------------------- |
| Name                 | Vaultwarden                                                      |
| Client Launch URL    | `https://vault.${BASE_DOMAIN}`                                   |
| Callback URLs        | `https://vault.${BASE_DOMAIN}/identity/connect/oidc-signin`      |
| Logout callback URLs | `https://vault.${BASE_DOMAIN}`                                   |
| PKCE                 | enabled                                                          |
| Allowed groups       | `members`                                                        |

### Jellyfin

Jellyfin's OIDC support is via the [SSO plugin](https://github.com/9p4/jellyfin-plugin-sso). `setup.sh` pre-seeds the plugin into the Jellyfin config volume on first run, so you should see it under Admin → Dashboard → Plugins on first boot without any manual install. If you don't, restart Jellyfin once (`docker compose restart jellyfin`) or check `setup.sh` output for errors.

| Field                | Value                                                            |
| -------------------- | ---------------------------------------------------------------- |
| Name                 | Jellyfin                                                         |
| Client Launch URL    | `https://media.${BASE_DOMAIN}`                                   |
| Callback URLs        | `https://media.${BASE_DOMAIN}/sso/OID/redirect/pocket-id`        |
| Logout callback URLs | `https://media.${BASE_DOMAIN}`                                   |
| PKCE                 | enabled                                                          |
| Allowed groups       | `members`                                                        |

## 2. Paste the credentials into each service

### Vaultwarden

Edit `services/vaultwarden/.env` on the Apps VM:

```
SSO_ENABLED=true
SSO_ONLY=false                              # keep master password fallback
SSO_SIGNUPS_MATCH_EMAIL=true
SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION=true   # Pocket ID doesn't assert verified status
SSO_PKCE=true
SSO_SCOPES=email profile
SSO_CLIENT_ID=<from Pocket ID>
SSO_CLIENT_SECRET=<from Pocket ID>
```

Then:
```bash
docker compose up -d vaultwarden
```

Test at `https://vault.${BASE_DOMAIN}` — click **Sign in with SSO** → passkey auth at Pocket ID → redirected back → prompted to set master passphrase (first time only) or enter existing passphrase → vault opens.

**How auth layers work:** SSO authenticates "who you are" to the Vaultwarden server. Master passphrase derives the vault encryption key on your device. They're independent — Pocket ID outage doesn't lock you out (master password fallback stays enabled), and master passphrase compromise doesn't affect SSO identity. See [vaultwarden auth memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_vaultwarden_auth.md) for the full model.

#### Install Bitwarden clients (self-hosted server URL configuration)

The web UI works, but for daily use every member installs the Bitwarden desktop + browser extension + mobile app, all pointed at the self-hosted server. **Don't skip the server-URL step or the client talks to Bitwarden Cloud instead and fails mysteriously.**

**Desktop (macOS):**
```bash
brew install --cask bitwarden   # or download from bitwarden.com/download
```
Launch the app. On the login screen:
1. Click the **gear / settings icon** at the top-right of the login form
2. Choose **Self-hosted environment**
3. **Server URL:** `https://vault.${BASE_DOMAIN}`
4. Save
5. Log in with your email → click **Enterprise single sign-on** → enter any non-empty SSO identifier (Vaultwarden uses `VW_DUMMY_IDENTIFIER` internally; your entry is cosmetic) → passkey → master passphrase → vault
6. Settings → Preferences → enable **Unlock with Touch ID** (or Windows Hello / equivalent)

**Browser extension (Chrome / Safari / Firefox):**
1. Install Bitwarden from the browser's extension store. (On Safari, the Mac App Store version of Bitwarden bundles the Safari extension — enable it under Safari → Preferences → Extensions.)
2. Open the extension → gear icon on login → same self-hosted URL config as desktop
3. Log in the same way (SSO + master passphrase)
4. Enable biometric unlock if offered

**Mobile (iOS / Android):**
1. Install Bitwarden from App Store / Play Store
2. On the login screen, tap the **gear/settings icon** at the top-right
3. Set **Server URL** to `https://vault.${BASE_DOMAIN}` under Self-hosted environment
4. Log in via SSO + master passphrase + biometric unlock
5. **iOS: enable AutoFill** under Settings → Passwords → AutoFill Passwords → Bitwarden. **Android: enable the Bitwarden accessibility/autofill service** so passkey and password filling works across apps.

**Sanity checks after client install:**
- Open a non-coralstack website in your browser → extension autofills saved credentials
- Lock + unlock the vault via biometric to confirm offline unlock works (proves master passphrase cached in keychain, not just server-side)
- On mobile: set phone to airplane mode and try unlocking the vault — should succeed (vault contents cache locally; you only need network for sync and SSO re-auth)

### Jellyfin

Admin → Plugins → SSO-Auth → Add Provider:

| Field                     | Value                                         |
| ------------------------- | --------------------------------------------- |
| Name of OIDC Provider     | pocket-id                                     |
| OIDC Endpoint             | `https://id.${BASE_DOMAIN}`                   |
| OIDC Client ID            | (from Pocket ID)                              |
| OIDC Secret               | (from Pocket ID)                              |
| Enabled                   | on                                            |
| Enable Authorization by Plugin | on                                       |
| Roles                     | leave blank (or map Pocket ID groups later)   |

The login URL becomes `https://media.${BASE_DOMAIN}/sso/OID/start/pocket-id` —
add a link to it from the Jellyfin login page via the branding settings.

## 3. Add more community members

1. In Pocket ID, create the user → assign to `members` group.
2. Have the user sign in at `https://id.${BASE_DOMAIN}` and register a passkey (Safari for smoothest iCloud Keychain handoff).
3. They then sign into Vaultwarden / Jellyfin / other services via the "Sign in with SSO" button — accounts are auto-provisioned via `SSO_SIGNUPS_MATCH_EMAIL`.
4. **For Vaultwarden specifically:** first SSO login triggers a "set master passphrase" prompt (thanks to OIDCWarden fork — mainline bounces here). Walk them through Diceware generation + writing it on paper for their safe. This is a one-time step per member.

Budget ~15 minutes per new member for hand-holding the first time. Most of that is explaining the two-credential model below, not technical setup.

## The "two-credential" model for members

Each member has exactly two things they need to remember / keep safe:

- **Pocket ID passkey** — stored in their device's OS keychain (iCloud Keychain / Windows Hello) or a hardware security key. Single biometric tap approves any SSO login across the coralstack (Vaultwarden, Jellyfin, Ente, future services).
- **Vaultwarden master passphrase** — learned once, written on paper, stored in a physical safe. Decrypts the vault on each device. Independent of SSO — master passphrase compromise doesn't affect other services, Pocket ID outage doesn't lock vault.

Two credentials, two failure modes, never lose both at once. See the [secret tiering memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_secret_tiering.md) for the full taxonomy of what lives where.

### Where to store the Pocket ID root admin passkey

As a member/user, the primary passkey lives in your OS keychain. For the **admin** (root of SSO for the whole coralstack):

- **Primary:** iCloud Keychain (Safari, syncs across Apple devices) or equivalent
- **Backup:** a second passkey registered on either a hardware security key (YubiKey in safe) or in Vaultwarden itself — the latter is acceptable because Pocket ID compromise doesn't cascade into Vaultwarden (vault encryption is master-passphrase-derived, independent of SSO)
- **Recovery codes:** if Pocket ID surfaces them, print and store with paper Tier-1 credentials
- **Nuclear option:** set `MAINTENANCE_MODE=true` in `services/pocket-id/.env` + restart the container → allows re-bootstrapping admin if all passkeys are lost

Non-root passkeys (regular user SSO passkeys for daily service logins) can freely go in Vaultwarden.
