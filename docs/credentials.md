# Signing in: credential profiles

An agent can sign in to the app under test without ever seeing a secret. The project declares
accounts in a checked-in **`amoo.config.json`**; the agent passes a reference,
`credential="<profile>#<field>"`, and amoo resolves and types the value itself.

## `amoo.config.json`

Found by walking up from the working directory (the MCP server's, or the shell's for `amoo device`)
to the repository root, like `amoo.md`. A project without one behaves exactly as before.

Configs layer the way nested `AGENTS.md` files do. Every `amoo.config.json` on the way up applies, and
the nearer one wins. An orchestrator can keep shared profiles at its root while a platform repository
adds or overrides its own. Each file must be valid on its own. Profiles and their `fields` merge by
name, `requires_launch_env` merges by key, and a profile's `apps` list in the nearer file replaces the
outer one. `amoo config validate` lists every file it layered. Schema:
[`amoo-config.schema.json`](amoo-config.schema.json).

```json
{
  "version": 1,
  "profiles": {
    "mock-user": {
      "apps": ["com.example.app.qa"],
      "requires_launch_env": { "FIREBASE_AUTH_EMULATOR_HOST": "*" },
      "fields": {
        "email":    { "literal": "qa@example.test", "class": "identifier" },
        "password": { "literal": "any-password",    "class": "secret" }
      }
    },
    "staging-free-user": {
      "apps": ["com.example.app.qa"],
      "requires_launch_env": { "API_ENV": "staging" },
      "fields": {
        "email":    { "keychain": { "service": "amoo.example.qa", "account": "free-user-email" },    "class": "identifier" },
        "password": { "keychain": { "service": "amoo.example.qa", "account": "free-user-password" }, "class": "secret" }
      }
    }
  }
}
```

| Key | Meaning |
| --- | --- |
| `apps` | Bundle / package ids the profile may be typed into. |
| `requires_launch_env` | Launch environment amoo must have sent to the app; `*` means the key only has to be present. This is what keeps a staging account out of a build pointed elsewhere. |
| `fields.<name>.literal` | A value checked into the repository. Only for non-secrets, such as a mock backend that accepts any password. |
| `fields.<name>.keychain` | A generic-password item (`service`, `account`) in the user's keychain. Not available yet: resolves to `blocked: no credential store`. |
| `fields.<name>.class` | `secret` fills only a secure (password) field and is scrubbed from every amoo output; `identifier` (an email, a username) fills any field. |

`amoo config validate [--path <file>] [--json]` checks the file without reading any value.

## Using a credential

```text
# MCP
fill_field session_id=<id> id=login.email    credential=mock-user#email
fill_field session_id=<id> id=login.password credential=mock-user#password

# CLI: --runtime-id carries the launch between amoo device calls
amoo device --platform android --device emulator-5554 --runtime-id <rt> \
  device_launch_app app_id=com.example.app.qa environment=FIREBASE_AUTH_EMULATOR_HOST=10.0.2.2:9099
amoo device --platform android --device emulator-5554 --runtime-id <rt> \
  fill_field id=login.password credential=mock-user#password
```

`credential` is accepted by `fill_field`, `set_text` and `type_text` (and inside `run_steps`), and
replaces `text`/`value`. `type_text` takes only `identifier` fields, because amoo cannot check that
the focused field is secure.

Launch environment reaches iOS apps as process environment and Android apps as string Intent extras
on the launch intent.

## Guarantees and limits

- The gate checks amoo's **own** record of the launch: the session's `start_session` launch, or the
  last `device_launch_app` it performed. Relaunching with a different environment re-gates. It cannot
  know which backend a build really talks to; `requires_launch_env` ties the account to what amoo told
  the app.
- A `secret` value is registered for scrubbing before it is sent, then removed from every tool result,
  error message, `run_steps` summary, `report.json`, `plan.json` and `flow.json`. The recording keeps
  `credential=<profile>#<field>` and `<redacted, credential>`; `plan.json` carries a `redacted` warning,
  so code generation stops at that step instead of inventing a value.
- Screenshots are pixels and cannot be scrubbed. That is why secrets only fill secure fields; never
  reveal a password field on screen.
- For the CLI, the runtime record stores the last launch's app id and environment, with values under
  sensitive keys (`token`, `password`, …) masked, so such a key can only satisfy a `*` requirement.

## Results an agent returns to its caller

| Result | Cause |
| --- | --- |
| `blocked: no credentials` | No config, unknown profile or field, empty value, or no keychain item |
| `blocked: profile not allowed for <app>` | Not launched by amoo, wrong app, or missing launch environment |
| `blocked: credential store locked` | The keychain needs a person |
| `blocked: no credential store on this platform or build` | A keychain field on Linux or a build without a store |

These carry `"blocked": true` in structured content and are never retried.
