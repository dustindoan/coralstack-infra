# Monitor definitions

The CoralStack monitor set, as code. `setup.sh` renders this directory into
`${DATA_PATH}/autokuma/monitors`, where AutoKuma reads it:

- `*.toml` — copied as-is. No secrets, safe in a public repo.
- `*.toml.template` — `envsubst`'d with the push tokens from
  `services/autokuma/.env`. **Never commit a rendered push token.**

Filename (minus extension) is the AutoKuma ID and must be stable — renaming a
file makes AutoKuma treat it as a new monitor and orphan the old one.

Full property reference: <https://autokuma.bigboot.dev/dev/>
