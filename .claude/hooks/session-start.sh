#!/bin/bash
# gi-os iOS kit for Claude Code. Fetches gi-os/.github into .gios/ (gitignored), installs its
# shared skills into .claude/skills/, and prints the house rules into the session's context.
# Never fails the session: offline, it uses whatever .gios/ already has.
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
KIT=.gios
REF="${GIOS_KIT_REF:-main}"
{
  if [ -d "$KIT/.git" ]; then
    git -C "$KIT" fetch -q --depth 1 origin "$REF" && git -C "$KIT" reset -q --hard FETCH_HEAD
  else
    rm -rf "$KIT" && git clone -q --depth 1 --branch "$REF" https://github.com/gi-os/.github.git "$KIT"
  fi
} >/dev/null 2>&1 || echo "(Couldn't update the gi-os kit in $KIT; using what's there.)"
if [ -d "$KIT/.claude/skills" ]; then
  mkdir -p .claude/skills
  for s in "$KIT"/.claude/skills/gios-*; do
    [ -d "$s" ] || continue
    rm -rf ".claude/skills/$(basename "$s")" && cp -R "$s" .claude/skills/
  done
fi
cat "$KIT/ios/claude/CONTEXT.md" 2>/dev/null
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && cat "$KIT/ios/claude/CLOUD.md" 2>/dev/null
exit 0
