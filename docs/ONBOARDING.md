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

### Vaultwarden (when SSO graduates from alpha)

Vaultwarden's native SSO is experimental. Verify the current upstream docs
before enabling. Planned client config:

| Field                | Value                                                |
| -------------------- | ---------------------------------------------------- |
| Name                 | Vaultwarden                                          |
| Callback URLs        | `https://vault.${BASE_DOMAIN}/identity/connect/oidc-signin` |

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
