# Contributing

Issues and pull requests are welcome for the receive-only SDK surface described
in [API.md](API.md). Everyone taking part is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Report security problems privately, as
[SECURITY.md](SECURITY.md) describes, never in a public issue.

Before opening a pull request:

1. Keep changes within the package's receive-only boundary.
2. Add or update tests for changed behavior.
3. Run `swift test` and `swift test -c release`.
4. Run `scripts/check-public-content.sh`.
5. Update the changelog for user-visible changes.

By submitting a contribution, you agree that it may be distributed under the
repository's Apache License 2.0.

The license grants no right to use the OpenPush name, marks, or branding. Forks
and derivatives must use their own name and branding.
