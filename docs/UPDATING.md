# Updating an existing checkout

You already have both repositories cloned and pushed. A release zip is a
*tree*, not a patch, so unpack it somewhere else and copy the files over your
working copy — never unzip on top of a git repository, which leaves stale
files behind and can clobber `.git`.

```bash
# 1. unpack the release next to your checkout, not into it
ZIP=$(ls -t /mnt/c/Users/aleks/Downloads/hydra-skywater130-v5*.zip | head -1)
rm -rf /tmp/hydra-rel && mkdir -p /tmp/hydra-rel
unzip -q "$ZIP" -d /tmp/hydra-rel

# 2. copy in, keeping your .git, your .venv and your fetched vendor files
rsync -a --delete \
  --exclude '.git/' --exclude '.venv/' --exclude 'fpga/vendor_refs/' \
  --exclude 'tt/tile/' --exclude 'fpga/build/*/*.bit' \
  /tmp/hydra-rel/hydra-skywater130/ ~/src/hydra-skywater130/

# 3. see exactly what changed before you trust it
cd ~/src/hydra-skywater130
git status --short
git diff --stat
```

`--delete` is what removes files a release drops. If you have local edits you
want to keep, commit them first: rsync will overwrite them without asking.

Then verify, then push:

```bash
make verify
git add -A && git commit -m "..." && git push
```

If the push is refused over the `workflow` scope, the token cannot touch
`.github/workflows/`:

```bash
gh auth refresh -h github.com -s workflow && git push
# or use the SSH remote for this account
```
