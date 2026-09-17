gitsafe
One bash script that uploads your files to GitHub without the classicbeginner disasters. Give it a repo URL and what to upload — it handlesgit init, remotes, .gitignore, secret-scanning, size-checks, commitand push, with plain-English guidance at every step.

I built this after personally hitting almost every one of these mistakeswhile uploading my first projects. So the tool now prevents them.

what it protects you from
Beginner disaster	gitsafe's move
committing .env / API keys / private keys	pattern-scans every file, asks to exclude, records in .gitignore
GitHub's 100MB file limit rejecting everything	size-checked BEFORE anything happens, filename shown
"Please tell me who you are" mid-commit	detects missing git identity, guided one-time setup
! [rejected] — remote has work you don't have	fetches and merges remote first; plain-English conflict help
accidental --force wiping the remote	impossible without --force AND two confirmations
master vs main chaos	always uses main
GitHub rejecting your password	detects auth failure, explains the PAT/SSH fix in the error
re-runs creating weird repo states	idempotent — re-running just stages/commits/pushes the new changes
usage
./gitsafe.sh                                      # fully interactive./gitsafe.sh -r https://github.com/you/repo.git -m "msg" .    # whole folder./gitsafe.sh -r git@github.com:you/repo.git a.sh b.md         # picked files
First run asks for your repo URL and what to upload. That's it.

self-test (offline, safe — local git only, pushes nothing)
./gitsafe.sh --selftest
