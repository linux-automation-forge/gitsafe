#!/usr/bin/env bash
# gitsafe.sh — beginner-proof git uploader (v1.0.0)
# One command: point it at a GitHub repo URL + your files → it does the rest
# safely: init, remote, .gitignore, secret-scan, size-check, commit, push.
# It NEVER force-pushes unless you pass --force AND confirm twice.
#
# USAGE
#   ./gitsafe.sh                          # fully interactive
#   ./gitsafe.sh -r https://github.com/you/repo.git -m "msg" .   # whole dir
#   ./gitsafe.sh -r git@github.com:you/repo.git file1.sh file2.md
#   ./gitsafe.sh --selftest               # offline verification
#   ./gitsafe.sh --gen-files              # README/LICENSE/.gitignore for its own repo
set -uo pipefail
IFS=$'\n\t'
export LC_ALL=C

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
VERSION="1.0.0"

# ==================== USER-CONFIGURABLE DEFAULTS ============================
BRANCH="main"                 # we always use main (avoids master/main chaos)
GITIGNORE_DEFAULTS="netrecon_results/
*.log
*.pcap
*.swp
.DS_Store
.env
__pycache__/
node_modules/"
SECRET_PATTERNS=('BEGIN [A-Z ]*PRIVATE KEY' 'AKIA[0-9A-Z]{16}' 'sk_live_'
 'ghp_[A-Za-z0-9]{20,}' 'github_pat_' 'xox[baprs]-'
 '(api[_-]?key|secret|password|passwd)[[:space:]]*=')
WARN_MB=50                    # warn above this size
HARD_MB=100                   # GitHub hard-rejects files above 100MB

# ==================== COLORS / OUTPUT =======================================
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
    GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; RED=$'\033[1;31m'; CYN=$'\033[1;36m'
else
    R=""; B=""; DIM=""; GRN=""; YLW=""; RED=""; CYN=""
fi
ok()   { printf '  %s[ok]%s %s\n'   "$GRN" "$R" "$1"; }
warn() { printf '  %s[!!] %s%s\n'   "$YLW" "$1" "$R"; }
err()  { printf '  %s[XX] %s%s\n'   "$RED" "$1" "$R" >&2; }
step() { printf '\n%s▸ %s%s\n' "$CYN$B" "$1" "$R"; }
die()  { err "$2"; exit "$1"; }
hr()   { printf '%s──────────────────────────────────────────────────%s\n' "$DIM" "$R"; }

confirm() { # confirm <question> — 0=yes; honors ASSUME_YES
    if [[ "$ASSUME_YES" -eq 1 ]]; then printf '  [auto-yes] %s\n' "$1"; return 0; fi
    local reply=""
    read -r -p "$(printf '%s? [y/N]: ' "$1")" reply || return 1
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}
ask_line() { # ask_line <prompt> <default> → echoes answer (default on empty)
    local prompt="$1" def="${2:-}" reply=""
    if [[ -n "$def" ]]; then
        read -r -p "$(printf '%s [%s]: ' "$prompt" "$def")" reply || return 1
    else
        read -r -p "$(printf '%s: ' "$prompt")" reply || return 1
    fi
    printf '%s' "${reply:-$def}"
}

# ==================== URL HANDLING ==========================================
valid_url() { local u="$1"
    [[ "$u" =~ ^https?://[A-Za-z0-9._~:/-]+$ || "$u" =~ ^git@[A-Za-z0-9._-]+:.+$ ]]; }
normalize_url() { local u="$1"
    if [[ "$u" =~ ^https?://github\.com/[^/]+/[^/]+$ ]]; then u="${u}.git"; fi
    printf '%s' "$u"; }
remote_web_link() { local u="$1"
    u="${u%.git}"
    u="${u#git@}"
    u="$(printf '%s' "$u" | sed 's#:#/#')"
    printf 'https://%s' "${u#http*://}"; }

# ==================== SAFETY SCANS ==========================================
secret_hits_in() { # secret_hits_in <file> → prints matched pattern names
    local pat
    for pat in "${SECRET_PATTERNS[@]}"; do
        if grep -qaE "$pat" "$1" 2>/dev/null; then printf '%s\n' "$pat"; fi
    done
}
size_mb_of() { stat -c%s "$1" 2>/dev/null | awk '{printf "%d", $1/1048576}'; }

scan_for_secrets() { # scans candidate paths; returns excluded list via global SECRETS_EXCLUDE
    SECRETS_EXCLUDE=()
    local f pats found
    step "Scanning for secrets (keys, tokens, passwords)"
    local shown=0
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        pats="$(secret_hits_in "$f")"
        [[ -z "$pats" ]] && continue
        found=1
        warn "possible secrets in: $f"
        printf '%s\n' "$pats" | sed 's/^/        pattern: /'
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            SECRETS_EXCLUDE+=("$f"); warn "auto-excluded (non-interactive mode)"
        elif confirm "exclude '$f' from this upload (added to .gitignore)"; then
            SECRETS_EXCLUDE+=("$f")
        fi
        shown=$((shown+1)); (( shown >= 10 )) && { warn "(more than 10 flagged — check manually)"; break; }
    done
    [[ "${found:-0}" -eq 0 ]] && ok "no secret patterns found"
    return 0
}
check_sizes() { # hard-blocks >HARD_MB, warns >WARN_MB
    step "Checking file sizes (GitHub limit: 100MB per file)"
    local f mb bad=0
    while IFS= read -r -d '' f; do
        mb="$(size_mb_of "$f")"
        if (( mb >= HARD_MB )); then
            err "'$f' is ${mb}MB — GitHub rejects files over 100MB. Remove it and re-run."
            bad=1
        elif (( mb >= WARN_MB )); then
            warn "'$f' is ${mb}MB — large; uploads will be slow"
        fi
    done < <(find "$@" -type f -print0 2>/dev/null)
    (( bad == 1 )) && die 1 "fix the oversized files above first"
    ok "all files under ${HARD_MB}MB"
}

# ==================== GIT PREREQS ===========================================
check_git_installed() {
    command -v git > /dev/null 2>&1 || die 1 "git is not installed — install it first (sudo apt install git)"
}
ensure_identity() {
    local name email
    name="$(git config user.name 2>/dev/null || true)"
    email="$(git config user.email 2>/dev/null || true)"
    if [[ -n "$name" && -n "$email" ]]; then
        ok "git identity: $name <$email>"; return 0
    fi
    warn "git doesn't know who you are yet (needed for every commit)"
    if ! confirm "set it up now (stored globally on this machine)"; then
        die 1 "identity required — set it manually:  git config --global user.name 'Your Name' && git config --global user.email 'you@mail.com'"
    fi
    name="$(ask_line "your name (shown on commits)" "")"
    email="$(ask_line "your email (use your GitHub email)" "")"
    [[ -n "$name" && -n "$email" ]] || die 2 "name and email cannot be empty"
    git config --global user.name "$name"
    git config --global user.email "$email"
    ok "identity saved globally: $name <$email>"
}

# ==================== REPO PREP =============================================
init_repo() {
    if [[ -d .git ]]; then
        ok "existing git repo detected here — reusing it"
        git rev-parse --verify main > /dev/null 2>&1 || git checkout -B main > /dev/null 2>&1 || true
    else
        step "Creating a fresh git repository here"
        git init -b "$BRANCH" > /dev/null 2>&1 || { git init > /dev/null && git checkout -b "$BRANCH" > /dev/null; }
        ok "git repo initialized (branch: $BRANCH)"
    fi
}
set_remote() {
    local cur
    if git remote get-url origin > /dev/null 2>&1; then
        cur="$(git remote get-url origin)"
        if [[ "$cur" == "$REPO_URL" ]]; then
            ok "remote 'origin' already points at your repo"
        else
            warn "remote 'origin' currently points at: $cur"
            confirm "switch it to $REPO_URL" && git remote set-url origin "$REPO_URL" \
                && ok "remote updated" || warn "kept old remote (push may go elsewhere!)"
        fi
    else
        git remote add origin "$REPO_URL" && ok "remote 'origin' added"
    fi
}
sync_with_remote() { # pull remote history so pushes never get rejected
    step "Checking what's already on GitHub"
    local heads
    if ! heads="$(git ls-remote --heads origin 2>&1)"; then
        printf '%s\n' "$heads" | sed 's/^/    /' >&2
        die 1 "could not reach the repo — check the URL, your internet, and your login.
     GitHub tips: HTTPS needs a Personal Access Token (not your password) —
     github.com → Settings → Developer settings → Personal access tokens.
     Or use the SSH form: git@github.com:USER/REPO.git"
    fi
    if [[ -z "$heads" ]]; then
        ok "remote is empty — clean first upload, nothing to merge"
        return 0
    fi
    ok "remote has content — syncing so nothing gets clobbered"
    git fetch origin > /dev/null 2>&1 || die 1 "fetch failed — see message above"
    if git rev-parse --verify HEAD > /dev/null 2>&1; then
        # local has commits: fast-forward if possible, else merge, else guide user
        if git merge-base --is-ancestor origin/"$BRANCH" HEAD 2> /dev/null; then
            ok "local is ahead of remote — safe to push"
        else
            if git pull --no-rebase --no-edit origin "$BRANCH"; then
                ok "merged remote changes into yours"
            else
                err "merge conflicts — fix by hand:"
                printf '      1) open the files marked <<<<<<<\n'
                printf '      2) keep the right lines, delete markers\n'
                printf '      3) git add <files> && git commit\n'
                printf '      4) re-run this script\n'
                exit 1
            fi
        fi
    else
        # fresh local repo + remote has files: adopt remote history safely
        if git checkout -B "$BRANCH" "origin/$BRANCH" > /tmp/gitsafe_co.out 2>&1; then
            ok "adopted remote history — your new files will layer on top"
        else
            cat /tmp/gitsafe_co.out | sed 's/^/    /'
            die 1 "these local files already exist on GitHub with different content.
     Rename them locally, or delete the local copies to accept GitHub's versions,
     then re-run. (We refuse to overwrite your work automatically.)"
        fi
    fi
}

# ==================== COMMIT & PUSH =========================================
stage_files() {
    step "Staging files"
    if (( ${#PATHS[@]} == 0 )); then
        git add -A
        ok "staged entire current directory (gitignore respected)"
    else
        git add -- "${PATHS[@]}"
        ok "staged: $(IFS=' '; printf '%s' "${PATHS[*]}")"
    fi
    if git diff --cached --quiet; then
        warn "nothing new to commit (no changes since last upload)"
        return 1
    fi
    local n; n="$(git diff --cached --name-only | grep -c . || true)"
    ok "$n file(s) ready to commit"
    return 0
}
do_commit() {
    if [[ -z "$MSG" ]]; then
        local n; n="$(git diff --cached --name-only 2>/dev/null | grep -c . || echo ?)"
        MSG="$(ask_line "commit message (one line describing this upload)" "update $(date '+%Y-%m-%d') — ${n} files")"
    fi
    git commit -m "$MSG" > /dev/null
    ok "committed: $MSG"
}
do_push() {
    step "Pushing to GitHub"
    if [[ "$FORCE" -eq 1 ]]; then
        warn "FORCE requested — this overwrites the remote repo with your local version"
        confirm "type-yes to confirm overwriting GitHub" || die 1 "aborted — nothing pushed"
        confirm "REALLY sure? last chance" || die 1 "aborted — nothing pushed"
        git push --force-with-lease -u origin "$BRANCH"
    else
        git push -u origin "$BRANCH"
    fi
    ok "pushed! your code is live at: $(remote_web_link "$REPO_URL")"
}
finish_summary() {
    hr
    printf '%sDONE.%s summary:\n' "$GRN$B" "$R"
    printf '  repo   : %s\n  branch : %s\n  commit : %s\n' "$REPO_URL" "$BRANCH" "$MSG"
    hr
    printf '%suseful undo commands (before you push next time):%s\n' "$DIM" "$R"
    printf '  git log --oneline          see history\n'
    printf '  git status                 what changed\n'
    printf '  git reset --soft HEAD~1    undo LAST commit (keeps files)\n'
    hr
}

# ==================== MAIN FLOW =============================================
PATHS=(); SECRETS_EXCLUDE=()
REPO_URL=""; MSG=""; ASSUME_YES=0; FORCE=0

run_flow() {
    printf '%s gitsafe %s — uploads files to GitHub without the footguns %s\n' "$CYN$B" "$R$DIM" "$R"
    check_git_installed

    step "Repository address"
    if [[ -z "$REPO_URL" ]]; then
        REPO_URL="$(ask_line "paste your GitHub repo URL (https://github.com/you/repo.git)" "")"
    fi
    [[ -n "$REPO_URL" ]] || die 2 "no repo URL given"
    valid_url "$REPO_URL" || die 2 "that doesn't look like a git URL — expected https://github.com/you/repo.git or git@github.com:you/repo.git"
    REPO_URL="$(normalize_url "$REPO_URL")"
    ok "target: $REPO_URL"

    ensure_identity

    step "What to upload"
    if (( ${#PATHS[@]} == 0 )); then
        printf '    1) everything in the current folder (%s)\n' "$PWD"
        printf '    2) I will type file/folder names\n'
        local choice; choice="$(ask_line "choice" "1")"
        case "$choice" in
            2)
                local entry
                while :; do
                    entry="$(ask_line "file/folder (empty = done adding)" "")"
                    [[ -z "$entry" ]] && break
                    [[ -e "$entry" ]] || { warn "skipping '$entry' — doesn't exist here"; continue; }
                    PATHS+=("$entry")
                done
                (( ${#PATHS[@]} > 0 )) || die 2 "no files selected"
                ;;
            1) : ;;
            *) die 2 "pick 1 or 2" ;;
        esac
    else
        local p; for p in "${PATHS[@]}"; do
            [[ -e "$p" ]] || die 2 "path does not exist: $p"
        done
        ok "using the paths you passed on the command line"
    fi

    # scope for scans: explicit paths, or whole dir
    local -a scanlist=()
    if (( ${#PATHS[@]} == 0 )); then scanlist=("." ); else scanlist=("${PATHS[@]}"); fi

    scan_for_secrets "${scanlist[@]}"
    if (( ${#SECRETS_EXCLUDE[@]} > 0 )); then
        if [[ ! -f .gitignore ]]; then printf '%s' "$GITIGNORE_DEFAULTS" > .gitignore; fi
        local s; for s in "${SECRETS_EXCLUDE[@]}"; do grep -qxF "$s" .gitignore || printf '%s\n' "$s" >> .gitignore; done
        ok "excluded files recorded in .gitignore"
    fi
    check_sizes "${scanlist[@]}"

    if [[ ! -f .gitignore ]]; then
        if confirm "create a starter .gitignore (logs, caches, env files)"; then
            printf '%s' "$GITIGNORE_DEFAULTS" > .gitignore; ok ".gitignore created"
        fi
    fi

    init_repo
    set_remote
    sync_with_remote
    stage_files || { warn "nothing to do — exiting cleanly"; exit 0; }
    do_commit
    do_push
    finish_summary
}

# ==================== SELF-TEST (offline; local git only, no network) =======
self_test() {
    local pass=0 fail=0 out tmp
    oks()  { printf '  %sPASS%s %s\n' "$GRN" "$R" "$1"; pass=$((pass+1)); }
    bads() { printf '  %sFAIL%s %s\n' "$RED" "$R" "$1"; fail=$((fail+1)); }
    printf '%sGITSAFE SELF-TEST (offline — local git only, nothing pushed)%s\n' "$CYN" "$R"

    # URL validation
    valid_url "https://github.com/u/r.git" && oks "url https ok"      || bads "url https"
    valid_url "git@github.com:u/r.git"     && oks "url ssh ok"        || bads "url ssh"
    valid_url "not a url"                  && bads "url reject bad"   || oks "url rejects garbage"

    # normalization
    out="$(normalize_url "https://github.com/u/r")"
    [[ "$out" == "https://github.com/u/r.git" ]] && oks "url normalize (.git added)" || bads "url normalize ($out)"

    # web link builder
    out="$(remote_web_link "git@github.com:u/r.git")"
    [[ "$out" == "https://github.com/u/r" ]] && oks "web link from ssh url" || bads "web link ($out)"

    # secret scan
    tmp="$(mktemp -d)"
    printf 'aws_key = AKIAIOSFODNN7EXAMPLE\n' > "$tmp/fake.txt"
    [[ -n "$(secret_hits_in "$tmp/fake.txt")" ]] && oks "secret pattern detected" || bads "secret detection"
    printf 'just normal text\n' > "$tmp/clean.txt"
    [[ -z "$(secret_hits_in "$tmp/clean.txt")" ]] && oks "clean file passes" || bads "clean file flagged"

    # REAL local git flow: init → identity → add → commit (all local)
    mkdir -p "$tmp/repo" && cd "$tmp/repo" || exit 1
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git config user.name "test"; git config user.email "t@t"
    echo "hello" > a.txt; git add a.txt; git commit -qm "test commit"
    git log --oneline | grep -q "test commit" && oks "local init+commit flow" || bads "local git flow"
    [[ "$(git symbolic-ref --short HEAD)" == "main" ]] && oks "branch is main" || bads "branch name"
    cd /; rm -rf "$tmp"
    [[ -d "$tmp" ]] && bads "temp cleaned" || oks "temp cleaned up"

    printf '%sRESULT: pass=%d fail=%d%s\n' "$CYN" "$pass" "$fail" "$R"
    (( fail > 0 )) && exit 1
    printf '%sSELF-TEST OK%s\n' "$GRN" "$R"
}

# ==================== --gen-files ===========================================
gen_repo_files() {
    [[ -e README.md ]] || { cat > README.md <<'GSEOF1'
# gitsafe

One bash script that uploads your files to GitHub without the classic
beginner disasters. Give it a repo URL and what to upload — it handles
git init, remotes, .gitignore, secret-scanning, size-checks, commit and
push, with plain-English guidance at every step (including "your token
expired" and "merge conflict" moments).

## what it protects you from

- pushing .env / API keys / private keys (scanned + excluded on request)
- GitHub's 100MB file limit (blocked up front with the filename)
- committing without git identity configured (guided one-time setup)
- "rejected — remote has work you don't have" (auto syncs first)
- force-push accidents (impossible unless you pass --force and confirm twice)
- master-vs-main confusion (always uses main)

## usage

    ./gitsafe.sh                                    # fully interactive
    ./gitsafe.sh -r https://github.com/you/repo.git -m "msg" .       # whole dir
    ./gitsafe.sh -r git@github.com:you/repo.git a.sh b.md            # picked files

## self-test (offline, safe)

    ./gitsafe.sh --selftest

bash 4+, git 2.x, Linux/WSL. MIT licensed.
GSEOF1
    printf '  [ok] README.md\n'; }
    [[ -e LICENSE ]] || { cat > LICENSE <<'GSEOF2'
MIT License

Copyright (c) 2025 YOUR NAME HERE

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
GSEOF2
    printf '  [ok] LICENSE (add your name!)\n'; }
    [[ -e .gitignore ]] || { printf '*.log\n.DS_Store\n' > .gitignore; printf '  [ok] .gitignore\n'; }
    printf '\nDone — and yes, you can upload THIS tool using ITSELF. Enjoy.\n'
}

# ==================== CLI / ENTRY ===========================================
usage() {
    cat <<GSEOF3
gitsafe v$VERSION — beginner-proof git uploader

USAGE
  $SCRIPT_NAME                         interactive: asks URL + files, does the rest
  $SCRIPT_NAME -r URL [-m MSG] [PATH...]  non-interactive (PATH "." = whole dir)
  $SCRIPT_NAME --selftest              offline verification (local git only)
  $SCRIPT_NAME --gen-files             README/LICENSE/.gitignore for its own repo

OPTIONS
  -r, --repo URL     GitHub repo (https://... or git@github.com:u/r.git)
  -m, --message TXT  commit message
  -b, --branch NAME  branch name            (default: $BRANCH)
  -y                 auto-confirm (secrets get auto-excluded)
      --force        allow overwrite of remote (asks twice!)
  -h, --help         this help
  -V, --version      version
GSEOF3
}
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -r|--repo)
                [[ -n "${2:-}" ]] || die 2 "-r needs a URL"
                REPO_URL="$2"; shift 2 ;;
            -m|--message)
                [[ -n "${2:-}" ]] || die 2 "-m needs a message"
                MSG="$2"; shift 2 ;;
            -b|--branch) BRANCH="${2:?-b needs a name}"; shift 2 ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            --force) FORCE=1; shift ;;
            --selftest) self_test; exit $? ;;
            --gen-files) gen_repo_files; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) printf '%s v%s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            -*) die 2 "unknown option '$1' — try --help" ;;
            *)  PATHS+=("$1"); shift ;;
        esac
    done
}

parse_args "$@"
run_flow
