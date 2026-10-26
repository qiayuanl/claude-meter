# ClaudeMeter

A macOS menu bar app that shows Claude subscription usage (session and weekly limits) for
several Claude Code accounts. The same email in two organizations counts as two accounts.

The menu bar shows a gauge and the tightest limit of the account in use, for example `69%`.
It turns orange at 80 % and red at 95 %, and shows `–` when there is no data, the last probe
failed, or the numbers are more than 30 minutes old. The popover lists every account with its
session, week and per-model limits, reset times, and extra usage when it is enabled.

## Build and install

Requires macOS 14 or later and Swift 6 (the Command Line Tools are enough).

```sh
make build     # debug build
make test      # unit tests (Swift Testing); plain `swift test` runs none with only the CLT
make app       # build/ClaudeMeter.app, signed ad hoc
make install   # copies the app to /Applications and registers it
```

`ClaudeMeter --probe-once <folder>` probes one account folder, prints the parsed result as
JSON and exits with status 1 when the probe failed. Each run is a real `/usage` request.

## Accounts

Each account is a Claude Code config folder in `~/.claude-accounts/<slug>`. **Add Account…**
asks for a name, creates the folder (mode 0700) and opens Terminal with `claude auth login`
for it. To track a second organization with the same email, add another account and pick that
organization while signing in. Settings renames (double-click), reorders (drag), signs in
again and removes accounts. Removing only forgets the account; the folder stays. Settings
warns when two accounts are signed in as the same email and organization.

## Which account is in use

Every 5 s ClaudeMeter reads `<folder>/sessions/<pid>.json` in each account folder and in
`~/.claude`, where plain `claude` runs. A session counts while its process is alive. A
folder's sessions belong to the account that matches the folder's current login (the email
and organization in `.claude.json` inside the folder, or `~/.claude.json` for `~/.claude`),
so switching with `/login` is followed. The session updated last decides; without a live
session the last account in use stays.

## Data source and rate limits

ClaudeMeter runs the official CLI and never reads credentials or calls Anthropic itself:

```sh
claude -p /usage --output-format stream-json --verbose --no-session-persistence --strict-mcp-config
claude auth status
```

Anthropic allows about 30 usage requests per hour per account, so ClaudeMeter probes one
account at a time, every account every 5 minutes, and on Refresh at most once per minute.
After a "rate limited" answer it skips that account for 15 minutes. "Updated" in the tooltip
is the time Claude Code fetched the numbers (`cachedUsageUtilization.fetchedAtMs`). A limit
whose reset time has passed counts as 0 %.

State lives in `~/Library/Application Support/ClaudeMeter/state.json` (no secrets). A file
that cannot be decoded is renamed to `state.json.bad` and the app starts fresh.

## License

GPL-3.0. See [LICENSE](LICENSE).
