# SSO Onboarding

How to wire Pocket ID as the OIDC provider for Immich and Jellyfin, so members
sign in once with a passkey and get into everything.

This is a manual process today. `setup.sh` generates the shared secrets; you
paste them into each service's admin UI. A future version may automate this
via Pocket ID's API.

## 0. First things first

1. Open `https://id.${BASE_DOMAIN}`.
2. Create the first admin user. Register a passkey (biometric preferred).
3. **Sign out and sign back in with the passkey** to confirm it works before
   trusting it as the only login.

## 1. Register each OIDC client in Pocket ID

In Pocket ID's admin UI, go to **OIDC Clients** → **Add Client** for each
service below. You'll get back a `client_id` and `client_secret` for each —
save them somewhere (you'll paste them into the service in a minute).

### Immich

| Field                | Value                                                |
| -------------------- | ---------------------------------------------------- |
| Name                 | Immich                                               |
| Callback URLs        | `https://photos.${BASE_DOMAIN}/auth/login`           |
|                      | `https://photos.${BASE_DOMAIN}/user-settings`        |
|                      | `app.immich:///oauth-callback` (mobile app deep link)|
| Logout callback URLs | `https://photos.${BASE_DOMAIN}`                      |

### Jellyfin

Jellyfin's OIDC support is via the [SSO plugin](https://github.com/9p4/jellyfin-plugin-sso).
`setup.sh` pre-seeds the plugin into the Jellyfin config volume on first run,
so you should see it under Admin → Dashboard → Plugins on first boot without
any manual install. If you don't, restart Jellyfin once
(`docker compose restart jellyfin`) or check `setup.sh` output for errors.

| Field                | Value                                                |
| -------------------- | ---------------------------------------------------- |
| Name                 | Jellyfin                                             |
| Callback URLs        | `https://media.${BASE_DOMAIN}/sso/OID/redirect/pocket-id` |
| Logout callback URLs | `https://media.${BASE_DOMAIN}`                       |

### Vaultwarden — intentionally *not* SSO'd

Vaultwarden stays on master passphrase + device biometric unlock, not OIDC.
This is a deliberate decision — see [the architecture note](#why-vaultwarden-stays-out-of-sso).

## 2. Paste the credentials into each service

### Immich

Immich admin → **Settings** → **Authentication** → **OAuth**.

| Field                     | Value                                         |
| ------------------------- | --------------------------------------------- |
| Enabled                   | on                                            |
| Issuer URL                | `https://id.${BASE_DOMAIN}`                   |
| Client ID                 | (from Pocket ID)                              |
| Client Secret             | (from Pocket ID)                              |
| Scope                     | `openid email profile`                        |
| Auto Register             | on (if you want members to self-provision)    |

Save, sign out, and test the "Login with OIDC" button.

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

1. In Pocket ID, create user accounts (or enable self-registration).
2. Each user signs in at `https://id.${BASE_DOMAIN}` and registers a passkey.
3. They then sign into Immich / Jellyfin via the OIDC button — accounts are
   auto-provisioned if you enabled that.

The one-passkey-per-person story only works if you actually test the passkey
flow on each device. Budget 15 minutes per new member for hand-holding the
first time.

## Why Vaultwarden stays out of SSO

Password managers are the one service that shouldn't go through your identity
provider. Three reasons:

1. **Break-glass recovery.** If Pocket ID ever breaks (corrupted DB, misconfig,
   lost admin passkey), you need to be able to get into Vaultwarden to retrieve
   recovery credentials. SSO'ing Vaultwarden through Pocket ID creates a
   circular dependency — the thing you'd need to recover is behind the thing
   that's broken.
2. **Industry pattern.** 1Password, Bitwarden Cloud, and every other serious
   password manager keeps its own auth for the same reason. We inherit this.
3. **Mobile apps don't speak OIDC anyway.** Bitwarden's mobile clients use
   master password + biometric unlock, regardless of what the server supports.

**The revised "one passkey" story** for household members:

- **Vaultwarden:** learn a Diceware master passphrase once. Unlock daily via
  Touch ID / Face ID on each device. Separate root of trust.
- **Everything else (Immich, Jellyfin, future services):** one Pocket ID
  passkey stored in the OS keychain (iCloud Keychain, Windows Hello, hardware
  key). Single biometric approves any OIDC login.

Two credentials, two failure modes, never lose both at once.

### Where to store the Pocket ID root admin passkey

**Not in Vaultwarden** — that's the circular dependency. Store it in:
- iCloud Keychain (Safari, auto-syncs to iPhone/iPad)
- Windows Hello / Google Password Manager (Chrome)
- A hardware security key (YubiKey, Titan) as a backup

Enroll at least **two** passkeys so a lost device doesn't lock you out.
Non-root passkeys (regular user accounts for Immich/Jellyfin etc.) *can*
go in Vaultwarden — they're not the keys to the identity system itself.
