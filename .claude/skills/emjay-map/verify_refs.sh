#!/usr/bin/env bash
# Check an emjay-map onboarding doc: every data-ref="path[:line[-end]]" must
# point at an existing path (and an in-range line), and no {{PLACEHOLDER}} may
# remain. Usage: verify_refs.sh <doc.html> [repo-root]
set -u

doc=${1:?usage: verify_refs.sh <doc.html> [repo-root]}
root=${2:-$(git -C "$(dirname "$doc")" rev-parse --show-toplevel 2>/dev/null || pwd)}
fail=0 checked=0

while IFS= read -r ref; do
  [[ -z $ref ]] && continue
  checked=$((checked + 1))
  path=${ref%%:*} lines=
  [[ $ref == *:* ]] && lines=${ref#*:}
  if [[ ! -e $root/$path ]]; then
    echo "missing   $ref"; fail=1; continue
  fi
  [[ -z $lines ]] && continue
  if [[ -d $root/$path || ! $lines =~ ^[0-9]+(-[0-9]+)?$ ]]; then
    echo "bad-line  $ref"; fail=1; continue
  fi
  last=${lines#*-}
  total=$(wc -l < "$root/$path")
  if (( last > total + 1 || ${lines%%-*} < 1 )); then
    echo "out-of-range $ref (file has $total lines)"; fail=1
  fi
done < <(grep -o 'data-ref="[^"]*"' "$doc" | sed 's/^data-ref="//; s/"$//' | sort -u)

placeholders=$(grep -on '{{[A-Z_]*}}' "$doc" || true)
if [[ -n $placeholders ]]; then
  echo "leftover placeholders:"; echo "$placeholders" | sed 's/^/  line /'; fail=1
fi

echo "checked $checked refs under $root"
exit $fail
