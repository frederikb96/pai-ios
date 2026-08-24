# PAI iOS

Native iOS client for [PAI Cloud](https://github.com/frederikb96/pai-cloud) — drive Claude Code
sessions running on the Cloud Kai VM from an iPhone.

Third client against the same backend, alongside the web UI and
[pai-android](https://github.com/frederikb96/pai-android). It is a port of the **web UI**, not of
the Android app: the web client is the newer implementation and owns the design, the transcript
model and the scrolling behaviour.

## Status

Early. The repository is scaffolded and the release pipeline is written, but nothing has been
compiled yet — there is no Mac. See `.claude/CLAUDE.md` for how that is arranged.

## Layout

| Path | What |
|---|---|
| `PAIKit/` | Swift package holding the logic and its tests — **where the code is** |
| `PAI/`, `PAITests/` | app target, empty until the Xcode project is created on the first Mac |
| `Config/` | xcconfig files; `MARKETING_VERSION` is overridden by CI from the git tag |
| `Tooling/mac-setup.sh` | turns a freshly rented Mac into a working build box |
| `fastlane/` | build, sign and TestFlight upload — the same lanes locally and in CI |

## Building

Requires macOS. Freddy owns no Mac, so builds happen on a rented Apple silicon box or in CI —
the `ios` skill covers how to get one and how to drive it headlessly.

```
bundle install
bundle exec fastlane beta
```

## Releasing

Push a `v*.*.*` tag, or run the release workflow manually. The tag is the single source of truth
for the version; the build number comes from the CI run number. TestFlight builds expire after
90 days, so a long-lived install needs a rebuild roughly quarterly.
