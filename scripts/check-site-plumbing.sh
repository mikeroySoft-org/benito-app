#!/bin/sh
# Assemble and check Pages locally without deploying or modifying the source site.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cp -R site "$tmp/_site"
site="$tmp/_site"
rm -rf "$site/README.md" "$site/tests"
jq --arg id 'TEAMID.org.example.benito' '.applinks.details[0].appIDs = [$id]' \
    site/.well-known/apple-app-site-association > "$site/.well-known/apple-app-site-association"
test -f "$site/.nojekyll"
test "$(cat "$site/CNAME")" = 'benito.mikeroysoft.com'
jq -e '.applinks.details[0].components | map(."/") | index("/join/*")' \
    "$site/.well-known/apple-app-site-association" > /dev/null
for page in index.html privacy/index.html support/index.html join/index.html 404.html; do
    test -f "$site/$page" || { echo "missing $page" >&2; exit 1; }
done
grep -q 'src="/assets/join.js"' "$site/join/index.html"
for hook in data-join-open data-join-get data-join-copy 'data-when="ready"' 'data-when="expired"' 'data-when="invalid"'; do
    grep -q "$hook" "$site/join/index.html" || { echo "join page lost hook: $hook" >&2; exit 1; }
done
node --check site/assets/join.js
