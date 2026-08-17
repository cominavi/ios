# Operations preflight and status

`Scripts/cominavi-ops` is the read-only entry point for checking whether this
workspace can build, test, publish, and observe its long-running operations.
It discovers the primary ComiNavi checkout from Git's common directory, so the
same command works from the primary iOS checkout and detached Codex worktrees.

Run the full preflight before operational work:

```sh
Scripts/cominavi-ops doctor
```

The doctor verifies all discovered ComiNavi repositories, the active iOS
worktree, shared Git metadata, required tools, the locked Fastlane version, the
local App Store Connect key and its permissions, Xcode and Simulator access,
the latest crawler state, the active GitHub identity, live App Store Connect
API access, and Wrangler authentication. It performs only read-only remote
requests. Use `--local` when intentionally working offline, and `--json` for
automation:

```sh
Scripts/cominavi-ops doctor --local
Scripts/cominavi-ops doctor --json
```

The expected GitHub login defaults to `GalvinGao`; override it with
`COMINAVI_GITHUB_LOGIN`. App Store Connect uses the existing Fastlane API-key
configuration and falls back to the key in the primary iOS checkout when a
detached worktree does not contain ignored credentials. The key ID, issuer ID,
and key path remain overridable through `ASC_KEY_ID`, `ASC_ISSUER_ID`, and
`ASC_KEY_FILEPATH`.

For non-interactive Cloudflare deployment, provide both
`CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` outside the repository in
CI. On a developer machine, the doctor accepts Wrangler's stored credentials
only after `whoami` returns the exact account ID configured in
`server/wrangler.jsonc`. It never prints tokens or private-key contents.

## Unified operation status

Crawler and TestFlight operations expose the same versioned JSON envelope:

```json
{
  "schemaVersion": 1,
  "operation": "crawler.c108",
  "runId": "1786888806-1786892400",
  "state": "running",
  "stage": "publishing",
  "terminal": false,
  "startedAt": "2026-08-16T15:15:55.131Z",
  "heartbeatAt": "2026-08-16T15:22:51.000Z",
  "finishedAt": null,
  "message": "Crawler interval 1786888806 to 1786892400 is publishing.",
  "progress": {},
  "artifacts": {},
  "receipt": null,
  "error": null
}
```

Read or wait for either operation without manually correlating processes,
cursor files, summaries, receipts, and App Store Connect output:

```sh
Scripts/cominavi-ops status crawler
Scripts/cominavi-ops wait crawler --timeout 1800
Scripts/cominavi-ops status testflight --json
Scripts/cominavi-ops wait testflight --timeout 7200 --json
```

Crawler status is derived from its durable cursor, run state, summary,
publication outbox, realtime-snapshot receipt, and LaunchAgent state. A run is
terminally successful only after `pendingUntil` clears and the cursor records
the completed run. TestFlight lanes atomically update
`build/fastlane/operation-status.json` while preparing, building, uploading,
processing, verifying, completing, or failing. The status file and release
artifacts are ignored by Git.

`status` exits with 1 for a recorded failure. `wait` exits with 1 for a failed
terminal operation and 124 when its timeout expires. Invalid command usage
exits with 64.

The source workspace and status paths can be overridden for CI or fixtures:

- `COMINAVI_WORKSPACE_ROOT`
- `COMINAVI_COLLECTOR_OUTPUT_ROOT`
- `COMINAVI_OPERATION_STATUS_PATH`
