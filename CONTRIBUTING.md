# Contributing

Render builds live services straight from this repository's `main` branch, so
every change to `main` goes through a pull request whose CI is green at its
final commit. That includes one-line AlphaClaw pin bumps.

1. Push your change to a branch and open a pull request against `main`.
2. Wait for both CI checks to pass on the pull request's latest commit:
   - `unit + contract`: the fast tests (`npm test`).
   - `docker e2e`: builds the image and boots it, the way Render does
     (`npm run test:e2e`, about 20 minutes).
3. Merge with a squash merge. Don't push to `main` directly.

A red check means the image you are about to deploy is untested. Fix the
cause (or the test, if the test is what's wrong) before merging; never merge
over a red or pending check.

For what the tests cover and how to run them locally, see
[tests/README.md](tests/README.md). Record every change that reaches the image
(a pin bump, a baked tool, `start.sh`) with a `VERSION` bump and a
`CHANGELOG.md` entry.
