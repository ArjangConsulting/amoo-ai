# Signing in: credential profiles

An agent can sign in to the app under test without ever seeing a secret. The project declares
accounts in a checked-in **`amoo.config.json`**; the agent passes a reference,
`credential="<profile>#<field>"`, and amoo resolves and types the value itself.

## Adding an account

A person runs `amoo credentials add` in a terminal (guided `amoo init` offers the same step). It asks
for a profile name, the app ids the account may sign in to, where the values should live, the sign-in
name (any text: an email, a username, a phone number) and password, and any
launch environment amoo must have set, then writes the profile to the nearest `amoo.config.json` (the
repository root when there is none). You choose where the values live:

| Storage | What is saved | Use it for | Trade-off |
| --- | --- | --- | --- |
| **Plain text** | Both values in `amoo.config.json`, committed | Mock, QA and staging test accounts the team may share | Anyone who can read the repository can read them |
| **Environment variables** | Only the variable names (default `AMOO_<PROFILE>_<FIELD>`) | Accounts you do not want in the repository or the Keychain, CI | Must be set wherever amoo runs; an agent could print a variable exported in its own shell |
| **macOS Keychain** | Both values in the login Keychain as `amoo.<app id>` / `<profile>.<field>`; the file keeps references | Real accounts on one Mac | macOS may ask to approve amoo (see below) |

Every profile it writes has two fields, `login` and `password`, so agents pass
`credential=<profile>#login` and `credential=<profile>#password`. Hand-written profiles may name fields
anything. It never accepts a value as a flag or without a terminal, so an agent cannot add one.
`amoo credentials check [<profile>]` reports each field as found, missing, locked, set or not set,
never the value.

`amoo credentials remove <profile> [--yes]` removes the profile from the `amoo.config.json` that
defines it and deletes the Keychain items amoo created for it (those named `amoo.<app id>` /
`<profile>.<field>`); it never deletes an item a hand-written profile points at elsewhere. Replacing a
profile with `add` likewise deletes the Keychain items the old profile used and the new one does not.

**Environment variables** are read from the amoo process at sign-in. For MCP, put them in the `env` of
your AI client's amoo server configuration, which the agent's own shell does not see. For `amoo device`,
export them in the shell that runs it; an agent sharing that shell could print them, so prefer the MCP
server's env, or plain text for accounts that are safe to share.

**Keychain approval.** Items amoo saves trust the amoo binary, so agents read them without a prompt. A
rebuilt binary (a local debug build) has a new signature: macOS asks again, and an agent's read reports
`blocked: credential store locked` after 10 seconds instead of waiting. Run `amoo credentials check` and
choose **Always Allow**. Environment variables and plain text never need approval.

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
        "login":    { "literal": "qa@example.test", "class": "identifier" },
        "password": { "literal": "any-password",    "class": "secret" }
      }
    },
    "staging-free-user": {
      "apps": ["com.example.app.qa"],
      "requires_launch_env": { "API_ENV": "staging" },
      "fields": {
        "login":    { "keychain": { "service": "amoo.example.qa", "account": "free-user.login" },    "class": "identifier" },
        "password": { "keychain": { "service": "amoo.example.qa", "account": "free-user.password" }, "class": "secret" }
      }
    }
  }
}
```

| Key | Meaning |
| --- | --- |
| `apps` | Bundle / package ids the profile may be typed into. |
| `requires_launch_env` | Launch environment amoo must have sent to the app; `*` means the key only has to be present. This is what keeps a staging account out of a build pointed elsewhere. |
| `fields.<name>.literal` | A value checked into the repository: a mock, QA or staging test account anyone with the repository may use. |
| `fields.<name>.keychain` | A generic-password item (`service`, `account`) in the user's macOS login Keychain, written by `amoo credentials add`. On Linux it resolves to `blocked: no credential store`. |
| `fields.<name>.env` | An environment variable of the amoo process, read at sign-in. Unset resolves to `blocked: no credentials` naming the variable. |
| `fields.<name>.class` | `secret` fills only a secure (password) field and is scrubbed from every amoo output; `identifier` (a sign-in name: any text, such as an email or username) fills any field. |

`amoo config validate [--path <file>] [--json]` checks the file without reading any value;
`amoo credentials add` writes it for you.

## Using a credential

```text
# MCP
fill_field session_id=<id> id=login.name     credential=mock-user#login
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
| `blocked: no credentials` | No config, unknown profile or field, empty value, or no Keychain item; a person runs `amoo credentials add` |
| `blocked: profile not allowed for <app>` | Not launched by amoo, wrong app, or missing launch environment |
| `blocked: credential store locked` | The Keychain is locked, or macOS is asking whether amoo may read the item; a person runs `amoo credentials check` |
| `blocked: no credential store on this platform or build` | A keychain field on Linux or a build without a store |

These carry `"blocked": true` in structured content and are never retried.
