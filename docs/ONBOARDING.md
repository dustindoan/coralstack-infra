# SSO Onboarding

How to wire Pocket ID as the OIDC provider for Vaultwarden and Jellyfin so members
sign in once with a passkey, plus the separate Ente Photos onboarding flow (Ente
has no native OIDC and uses an SRP-derived encryption key — see [section 3](#3-ente-photos-onboarding)).

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

### Open WebUI

Open WebUI uses standard OIDC — no plugin required. OIDC is enabled automatically once `OAUTH_CLIENT_ID` is non-empty in `services/open-webui/.env`.

| Field                | Value                                                            |
| -------------------- | ---------------------------------------------------------------- |
| Name                 | Open WebUI                                                       |
| Client Launch URL    | `https://ai.${BASE_DOMAIN}`                                      |
| Callback URLs        | `https://ai.${BASE_DOMAIN}/oauth/oidc/callback`                  |
| Logout callback URLs | `https://ai.${BASE_DOMAIN}`                                      |
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
SSO_SCOPES=email profile groups   # `groups` is required for Pocket ID to emit the groups claim — its docs imply otherwise but the source is explicit
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
5. Log in with your email. **Note: Enterprise SSO via the desktop app is currently broken** with our Pocket ID + OIDCWarden combination (nonce mismatch on token exchange — under investigation upstream). For desktop, use **email + master passphrase** login instead. SSO via the browser extension and mobile apps still works.
6. Once logged in: **Settings → Preferences** and enable ALL of these (none are default-on; without them browser-extension biometric unlock will silently fail):
   - **Unlock with Touch ID** — daily unlock convenience
   - **Ask for Touch ID on app start** — biometric instead of master passphrase on app relaunch
   - **Allow browser integration** — required for the extension to talk to desktop
   - **Require verification for browser integration** — each browser session needs explicit approval (security layer; recommended on)

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
| Request Additional Scopes | `groups` (required — Pocket ID only emits the groups claim when the scope is explicitly requested) |
| Scheme Override           | `https` (Caddy terminates TLS; without this, the plugin generates `http://` callbacks that Pocket ID rejects) |
| Role Claim                | `groups`                                      |
| Admin Roles               | `admins`                                      |
| Roles                     | `members` (gates login to Pocket ID `members` group; blank to allow any authenticated user) |

The login URL becomes `https://media.${BASE_DOMAIN}/sso/OID/start/pocket-id` —
add a link to it from the Jellyfin login page via the branding settings.

### Open WebUI

Edit `services/open-webui/.env` and paste the credentials from Pocket ID:

```
OAUTH_CLIENT_ID=<from Pocket ID>
OAUTH_CLIENT_SECRET=<from Pocket ID>
```

Then:
```bash
docker compose up -d open-webui
```

The Pocket ID login button appears automatically on `https://ai.${BASE_DOMAIN}`. Members click **Sign in with Pocket ID**, authenticate, and their Open WebUI account is auto-provisioned on first login. Existing accounts (created before SSO was wired) are merged by email.

## 3. Ente Photos onboarding

Ente is the one service in the stack that **does not** integrate with Pocket ID. Ente Photos uses
SRP, where the user's password derives the end-to-end-encryption key — replacing the password with
OIDC would require a Bitwarden-Key-Connector-style redesign that upstream hasn't engaged with
([discussion #2241](https://github.com/ente-io/ente/discussions/2241), open since 2024). For the
trial we accept this and store each member's Ente password in their (already-Pocket-ID-SSO'd)
Vaultwarden vault. The model is exactly parallel to Vaultwarden's own master passphrase: an E2EE
encryption key, independent of SSO identity.

### Initial admin signup (one-time)

1. Open `https://photos.${BASE_DOMAIN}` → tap **Sign up** → enter your email + a fresh Diceware
   password. **Save the password to Vaultwarden immediately** under a "Self-hosted Ente" item.
2. Museum sends an email-verification OTT, but unless you've configured SMTP it goes to the
   container's stdout instead. Pull it:
   ```bash
   docker compose logs ente-museum | grep -i ott
   ```
3. Enter the OTT in the web app, set your encryption recovery code (write it down — Tier 1 paper
   per [secret tiering](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_secret_tiering.md)),
   land in the empty photo library.
4. **Lock down registration** so `photos.${BASE_DOMAIN}` isn't a self-serve account creator for
   the public internet:
   ```bash
   # find your numeric user ID (the SELECT email FROM users column doesn't
   # exist — Ente hashes/encrypts emails for E2EE, so user_id is your only
   # stable handle here)
   docker compose exec ente-postgres psql -U ente -d ente_db -c \
     "SELECT user_id FROM users;"
   # edit ${DATA_PATH}/ente/museum.yaml — set:
   #   internal:
   #     disable-registration: true
   #     admins:
   #         - <your numeric id>
   docker compose restart ente-museum
   ```
   **Use `admins:` (plural list), not `admin:` (singular).** The Ente CLI's
   admin endpoints (used in step 5 below) only honor the plural list form
   despite the schema's comment claiming singular is a valid shortcut.
5. **Grant your account effectively-unlimited storage** (museum's default subscription is the
   cloud-tier 10GB limit, which is enforced even on self-host). Install the Ente CLI on your
   workstation (not the apps VM — CLI is a user tool):
   ```bash
   # Mac mini / desktop. See https://github.com/ente-io/ente/releases?q=tag%3Acli-v0
   # for the current arch-specific tarball name.
   curl -fsSL -O https://github.com/ente-io/ente/releases/download/cli-v0.2.3/ente-cli-v0.2.3-darwin-arm64.tar.gz
   tar -xzf ente-cli-v0.2.3-darwin-arm64.tar.gz && chmod +x ente
   mkdir -p ~/.ente && cat > ~/.ente/config.yaml <<EOF
   endpoint:
       api: https://photos-api.${BASE_DOMAIN}
   EOF
   ./ente account add   # prompts for email, password, OTT (grab from museum logs)
   ./ente admin update-subscription -a <your-email> -u <your-email> --no-limit true
   ```
   Same `update-subscription` command is used per new household member during onboarding —
   capture it as the canonical recipe.

6. Install the Ente mobile app (App Store / Play Store). On the login screen, tap the dev/server
   icon (top-right gear in newer versions) → set **Server endpoint** to
   `https://photos-api.${BASE_DOMAIN}`. Sign in with email + your Ente password. Mobile is
   sign-in-only — there's no mobile signup path against a self-hosted instance.

### Per-member onboarding

When a new household joins:

1. In `${DATA_PATH}/ente/museum.yaml`, flip `internal.disable-registration: false`, then
   `docker compose restart ente-museum`.
2. Send the new member to `https://photos.${BASE_DOMAIN}`. Walk them through the same signup +
   Vaultwarden-save + recovery-code flow as the admin step above. (They sign in to their already-
   provisioned Vaultwarden via Pocket ID first, then create a new vault item for the Ente password
   they're about to set.)
3. Once the member's account exists, flip `disable-registration: true` again and restart museum.
4. Hand them the mobile-app server-URL configuration step. Budget ~30 minutes for the first member
   you onboard — most of it is explaining why Ente's password lives in Vaultwarden separately from
   their Pocket ID identity (the [two-credential model section below](#the-two-credential-model-for-members)
   is the primer to walk them through).

A spike is queued (path A in this stack's design discussions) to add OIDC-based provisioning to
museum, eliminating the OTT loop and the disable-registration toggle ritual. Until that lands, the
toggle dance above is the supported flow.

## 4. Add more community members

1. In Pocket ID, create the user → assign to `members` group.
2. Have the user sign in at `https://id.${BASE_DOMAIN}` and register a passkey (Safari for smoothest iCloud Keychain handoff).
3. They then sign into Vaultwarden / Jellyfin / other services via the "Sign in with SSO" button — accounts are auto-provisioned via `SSO_SIGNUPS_MATCH_EMAIL`.
4. **For Vaultwarden specifically:** first SSO login triggers a "set master passphrase" prompt (thanks to OIDCWarden fork — mainline bounces here). Walk them through Diceware generation + writing it on paper for their safe. This is a one-time step per member.
5. **For Ente Photos:** see [Per-member onboarding](#per-member-onboarding) above. Ente is the one service that doesn't auto-provision via SSO — needs the disable-registration toggle dance.

Budget ~30 minutes per new member for hand-holding the first time across the full stack. Most of that is explaining the two-credential model below + the Ente exception, not technical setup.

## The "two-credential" model for members

Each member has exactly two things they need to **remember / keep on paper**:

- **Pocket ID passkey** — stored in their device's OS keychain (iCloud Keychain / Windows Hello) or a hardware security key. Single biometric tap approves any SSO login across the coralstack (Vaultwarden, Jellyfin, future services).
- **Vaultwarden master passphrase** — learned once, written on paper, stored in a physical safe. Decrypts the vault on each device. Independent of SSO — master passphrase compromise doesn't affect other services, Pocket ID outage doesn't lock vault.

Two credentials, two failure modes, never lose both at once.

**Plus one credential that lives inside Vaultwarden, not in your head:**

- **Ente Photos password** — set during Ente signup, saved to the Vaultwarden vault as soon as it's created. You retrieve it from Vaultwarden whenever you configure Ente on a new device. Ente uses end-to-end encryption with the password as the key-derivation root, so it can't be replaced by SSO without a redesign upstream hasn't engaged with — see [the Ente OIDC memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_ente_oidc.md). The model is the same E2EE-key-independent-of-SSO pattern Vaultwarden's own master passphrase already uses.

Two paper credentials + Ente-password-in-Vaultwarden. See the [secret tiering memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_secret_tiering.md) for the full taxonomy of what lives where.

### Where to store the Pocket ID root admin passkey

As a member/user, the primary passkey lives in your OS keychain. For the **admin** (root of SSO for the whole coralstack):

- **Primary:** iCloud Keychain (Safari, syncs across Apple devices) or equivalent
- **Backup:** a second passkey registered on either a hardware security key (YubiKey in safe) or in Vaultwarden itself — the latter is acceptable because Pocket ID compromise doesn't cascade into Vaultwarden (vault encryption is master-passphrase-derived, independent of SSO)
- **Recovery codes:** if Pocket ID surfaces them, print and store with paper Tier-1 credentials
- **Nuclear option:** set `MAINTENANCE_MODE=true` in `services/pocket-id/.env` + restart the container → allows re-bootstrapping admin if all passkeys are lost

Non-root passkeys (regular user SSO passkeys for daily service logins) can freely go in Vaultwarden.
