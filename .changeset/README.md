# Changesets

This folder holds [changesets](https://github.com/changesets/changesets) — small
markdown files describing changes that haven't shipped yet.

**Workflow**
1. After making a change, run `npm run changeset` (or `npx changeset`) and pick a
   bump type (patch / minor / major) and write a short summary.
2. Commit the generated `.changeset/*.md` file with your PR.
3. The **Changesets** GitHub Action opens/updates a "Version Packages" PR that
   bumps `package.json` and updates `CHANGELOG.md`.
4. Merge that PR, then tag the new version (`git tag vX.Y.Z && git push --tags`)
   to trigger the **Release** workflow (build → DMG → GitHub Release).
