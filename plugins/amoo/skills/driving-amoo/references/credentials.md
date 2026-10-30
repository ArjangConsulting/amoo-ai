# Signing in without seeing a secret

amoo signs in by **reference**. The project declares accounts in a checked-in `amoo.config.json`;
you pass `credential="<profile>#<field>"` to `fill_field`, `set_text` or `type_text` and amoo types
the value itself. You never see, choose, or repeat the value.

```text
fill_field id=login.email    credential=mock-user#email
fill_field id=login.password credential=mock-user#password
```

`credential` replaces `text` / `value`; passing both, or adding `record_value`, is an error. It
works inside `run_steps` steps too.

## What amoo enforces

- **The app and launch environment.** A profile lists the apps it may be typed into and the launch
  environment amoo must have sent (`requires_launch_env`, `*` = key present). amoo checks its own
  record of the launch (`start_session` or `device_launch_app`), never what you claim. With the CLI,
  pass `--runtime-id` so the launch is remembered between `amoo device` calls.
- **Secrets only into secure fields.** A `secret` field fills only a password field. `type_text`
  refuses a secret because it cannot check the focused field; use `fill_field` with the field's id.
  An `identifier` (an email) fills any field.
- **The value never comes back.** Results, errors, `report.json`, `plan.json` and `flow.json` carry
  the reference name and `<redacted, credential>`. Generated tests stop at the redacted step; the app's
  own test helper fills it.

## Order of preference

1. A profile whose app and launch environment match this run. Prefer a mock (literal) profile when the
   project runs against mocks.
2. A keychain-backed profile for a real account.
3. Neither: report `blocked: no credentials` to the caller.

## Never

- Invent an account, or ask for a password in chat.
- Put a secret in `text`, `value`, `--env`, launch environment, or a probe.
- Tap "show password" or screenshot a field after revealing it; pixels cannot be scrubbed.
- Retry a `blocked:` result. Return it to the caller as-is:

| Result | Meaning | Caller's move |
| --- | --- | --- |
| `blocked: no credentials` | No `amoo.config.json`, unknown profile/field, or no keychain item | A person runs `amoo credentials add` |
| `blocked: profile not allowed for <app>` | Wrong app, or launched without the required environment | Relaunch through amoo with that environment, or use the right profile |
| `blocked: credential store locked` | The keychain needs a person to unlock or approve amoo | A person runs `amoo credentials check` |
| `blocked: no credential store on this platform or build` | Keychain profile on Linux or a build without one | Use a mock profile |

Accounts are added by a person with `amoo credentials add`, which refuses to run without a terminal.
Never run it, edit secret values in `amoo.config.json`, or call `security` yourself; report the gap.
`amoo config validate` checks the file without reading any value. See `docs/credentials.md`.
