#!/usr/bin/env bash
# Claude Code PreToolUse hook: block destructive commands in this repo. Exit 2 = block.
# The command is split into segments (; && || | & newline $( `); each segment is matched from its start after
# stripping wrappers (VAR=val, env, command, sudo, bash -c '…', …). Text inside arguments (commit messages,
# PR bodies) therefore never matches. Defense in depth, not a sandbox: server-side checks are the gate.
set -euo pipefail
shopt -s nocasematch
input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")
[ "$tool" = "Bash" ] || exit 0
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

F='[[:space:]]+'                                # one-or-more spaces
OPT='([[:space:]]+-[^[:space:]]+)*'             # flag tokens only, e.g. -chdir=x
ARGS='([[:space:]]+[^[:space:]]+)*'             # any tokens
GIT="git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]+)*"  # git + global flags
AWS="aws([[:space:]]+-?[^[:space:]]+)*"         # aws + global flags/values
END='([[:space:]]|$)'
rules=(
  "terraform${OPT}${F}(apply|destroy|import|force-unlock|taint|untaint)"
  "terraform${OPT}${F}state${F}(rm|push|mv)"
  # force/delete flags, +ref, :ref, or main as the target
  "${GIT}${F}push${ARGS}${F}(--force[^[:space:]]*|--delete|-[a-z]*[fd][a-z]*|\+[^[:space:]]+|:[^[:space:]]*|(([^[:space:]]*:)?(refs/heads/)?main))${END}"
  "${GIT}${F}reset${F}--hard"
  "gh${F}pr${F}merge"
  "gh${F}(pr|issue)${F}edit${ARGS}${F}--(add|remove)-label"   # labels are the human's approval channel
  "gh${F}secret"
  "gh${F}variable${F}set"
  "gh${F}api${ARGS}${F}(-X|--method)(=|[[:space:]]*)(DELETE|PUT|PATCH)${END}"
  "gh${F}api${ARGS}${F}[^[:space:]]*/merges?([/?[:space:]]|$)"
  "${AWS}${F}iam${END}"
  "${AWS}${F}s3${F}r[mb]${END}"
  "${AWS}${F}s3api${F}delete-"
  "${AWS}${F}ssm${F}(put|delete)-parameter"
  "${AWS}${F}sts${F}assume-role"
)
deny="^([^[:space:]]*/)?($(IFS='|'; echo "${rules[*]}"))"

strip() { # drop leading wrappers until the segment starts with the real command
  local s=$1 prev=
  while [ "$s" != "$prev" ]; do
    prev=$s
    s="${s#"${s%%[![:space:]\(\{\!]*}"}"
    if [[ $s =~ ^[a-z_][a-z0-9_]*=(\"[^\"]*\"|\'[^\']*\'|[^[:space:]]*)[[:space:]]*(.*)$ ]]; then s=${BASH_REMATCH[2]}; fi
    if [[ $s =~ ^(env|command|sudo|exec|nohup|time|eval|xargs)(${OPT})${F}(.*)$ ]]; then s=${BASH_REMATCH[4]}; fi
    if [[ $s =~ ^(bash|sh|zsh|dash)(${F}-[^[:space:]]+)*${F}-[a-z]*c[a-z]*${F}(.*)$ ]]; then s=${BASH_REMATCH[3]}; fi
    s="${s#[\'\"]}"
    s="${s%"${s##*[![:space:]\)\}\'\"]}"}"   # trailing space, quotes, ) } left by $( … ) or bash -c '…'
  done
  printf '%s' "$s"
}

rm_rf() { # rm with both a recursive and a force flag, any order/case/long form
  [[ $1 =~ ^([^[:space:]]*/)?rm${END} ]] || return 1
  local r=0 f=0 t toks
  read -ra toks <<<"$1"
  for t in "${toks[@]:1}"; do
    case $t in
      --recursive) r=1;; --force) f=1;; --*) ;;
      -*) [[ $t == *r* ]] && r=1; [[ $t == *f* ]] && f=1;;
    esac
  done
  ((r && f))
}

labels_write() { # gh api …/labels with a mutating method or request fields (GET stays allowed)
  [[ $1 =~ ^gh${F}api${F} && $1 =~ /labels([/?[:space:]]|$) ]] || return 1
  [[ $1 =~ ${F}(-X|--method)(=|[[:space:]]*)(POST|PUT|PATCH|DELETE)${END} || $1 =~ ${F}(-f|--field|--raw-field|--input)([=[:space:]]|$) ]]
}

graphql_unsafe() { # gh api graphql is allowed only when every -f/-F query= value is a read query
  local s=$1 found=0
  [[ $s =~ ^gh${F}api${F}(.*[[:space:]])?graphql${END} ]] || return 1
  [[ $s =~ mutation || $s =~ ${F}--input([=[:space:]]|$) ]] && return 0
  while [[ $s =~ (^|[[:space:]])(-f|--field|--raw-field)(=|[[:space:]]+)query=(.*)$ ]]; do
    s=${BASH_REMATCH[4]}; found=1
    [[ $s == query* ]] || return 0   # mutation, @file, or anything else
  done
  ((found == 0))
}

push_from_main() { # `git push [<remote> [HEAD|@]]` pushes the current branch; block it on main
  [[ $1 =~ ^${GIT}${F}push(${F}-[^[:space:]]+)*(${F}[^-[:space:]][^[:space:]]*(${F}(HEAD|@))?)?(${F}-[^[:space:]]+)*$ ]] || return 1
  [[ $(git rev-parse --abbrev-ref HEAD 2>/dev/null) == main ]]
}

branch_force_delete() { # -D, -df/-fd, or delete + force in any order/form; -d alone (merged only) passes
  [[ $1 =~ ^${GIT}${F}branch([[:space:]]|$) ]] || return 1
  local d=0 f=0 t toks
  read -ra toks <<<"${1#*branch}"
  shopt -u nocasematch   # -D vs -d matters here
  for t in "${toks[@]}"; do
    case $t in
      --delete) d=1;; --force) f=1;; --*) ;;
      -*D*) d=1; f=1;;
      -*) [[ $t == *d* ]] && d=1; [[ $t == *f* ]] && f=1;;
    esac
  done
  shopt -s nocasematch
  ((d && f))
}

block() {
  cat >&2 <<EOF
Blocked by Ned guardrails: '$1' is not allowed from an agent session.
Safe alternative: open a PR and let the guard check decide; for applies use the infra-aws workflow (manual dispatch, prod approval); for secrets/variables/labels ask the human on Telegram.
EOF
  exit 2
}

segments=${cmd//\$\(/$'\n'}
while IFS= read -r seg; do
  seg=$(strip "$seg")
  seg=${seg//[\'\"]/}   # after strip (which needs quotes for VAR="a b"): 'main', -X "DELETE", "terraform" apply
  [ -n "$seg" ] || continue
  if [[ $seg =~ $deny ]]; then block "${BASH_REMATCH[0]}"; fi
  for check in rm_rf labels_write graphql_unsafe push_from_main branch_force_delete; do
    if "$check" "$seg"; then block "$seg"; fi
  done
done < <(tr ';|&`' '\n\n\n\n' <<<"$segments")
exit 0
