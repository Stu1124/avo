# Contributing

Bug reports and pull requests are welcome. Open an issue first if you are unsure whether a change
fits.

1. Fork the repository and branch off `main`.
2. Make your change. `AGENTS.md` covers the build, the signing options and where everything lives;
   `docs/CONTRIBUTING-AGENTS.md` covers the types and conventions to follow when adding a tool or a
   card.
3. Run the tests: `scripts/test.sh`. Every line must print PASS. Add a `tests/*Tests.swift` file for
   logic you can test without the app running. The runner compiles each one against the sources
   listed on its first line.
4. Build cleanly:
   ```sh
   xcodegen generate >/dev/null && xcodebuild -project Avo.xcodeproj -scheme Avo \
     -configuration Debug -derivedDataPath /tmp/avo-dd CODE_SIGNING_ALLOWED=NO build 2>&1 \
     | grep -E 'error:|BUILD'
   ```
5. Open a pull request describing what changed and how you verified it on a Mac. CI runs the same
   tests and build.

By contributing you agree that your work is licensed under the MIT License in `LICENSE`.
