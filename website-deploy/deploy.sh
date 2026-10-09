#!/bin/sh
# Publish the committed website/ directory to https://app.aicove.online
# Only what is in git HEAD goes out; uncommitted or untracked files are never uploaded.
# First run on a machine: npx wrangler login
set -eu
cd "$(dirname "$0")"
rm -rf site && mkdir site
git -C .. archive HEAD website | tar -x -C site --strip-components=1
npx -y wrangler@4 deploy
rm -rf site
