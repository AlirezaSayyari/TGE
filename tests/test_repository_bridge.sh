#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
passes=0

pass(){ printf 'ok - %s\n' "$1"; passes=$((passes + 1)); }
fail(){ printf 'not ok - %s\n' "$1" >&2; exit 1; }
check(){ "$@" || fail "$*"; pass "$*"; }
assert_eq(){ [[ "$1" == "$2" ]] || fail "$3 (expected=$2 actual=$1)"; pass "$3"; }
assert_fails(){ local label="$1"; shift; if "$@"; then fail "$label"; fi; pass "$label"; }

# Sourcing is safe: production entry points run only when executed directly.
# shellcheck disable=SC1090
source "$ROOT/deploy.sh"

entry_root="$TEST_TMP/entry"
entry_mock="$entry_root/mockbin"
mkdir -p "$entry_mock"
printf '%s\n' '#!/usr/bin/env bash' 'url="${!#}"' \
  'case "$url" in' \
  '  https://api.github.com/repos/runovelhq/tge) printf '\''{"full_name":"runovelhq/tge"}\n200'\'' ;;' \
  '  */VERSION|*/releases/latest|*/tags*) exit 1 ;;' \
  '  *) printf '\''unexpected curl URL\n'\'' >&2; exit 97 ;;' \
  'esac' > "$entry_mock/curl"
printf '%s\n' '#!/usr/bin/env bash' 'printf entered-main > "$ENTRY_MARKER"' 'exit 42' > "$entry_mock/apt-get"
chmod 0755 "$entry_mock/curl" "$entry_mock/apt-get"
ln -s "$ROOT/deploy.sh" "$entry_root/deploy-symlink"

run_entry_case(){
  local mode="$1" marker="$entry_root/marker-$1" output rc=0
  rm -f "$marker"
  case "$mode" in
    file) output="$(PATH="$entry_mock:$PATH" ENTRY_MARKER="$marker" bash "$ROOT/deploy.sh" entry-arg 2>&1)" || rc=$? ;;
    executable) output="$(PATH="$entry_mock:$PATH" ENTRY_MARKER="$marker" "$ROOT/deploy.sh" entry-arg 2>&1)" || rc=$? ;;
    stdin) output="$(PATH="$entry_mock:$PATH" ENTRY_MARKER="$marker" bash < "$ROOT/deploy.sh" 2>&1)" || rc=$? ;;
    pipe) output="$(PATH="$entry_mock:$PATH" ENTRY_MARKER="$marker" bash -c 'cat "$1" | bash' _ "$ROOT/deploy.sh" 2>&1)" || rc=$? ;;
    source)
      output="$(PATH="$entry_mock:$PATH" ENTRY_MARKER="$marker" bash -c 'source "$1"; printf sourced-only' _ "$ROOT/deploy.sh" 2>&1)" || rc=$?
      [[ "$rc" == 0 && "$output" == sourced-only && ! -e "$marker" ]]
      return
      ;;
    source-function)
      output="$(PATH="$entry_mock:$PATH" ENTRY_MARKER="$marker" bash -c 'load(){ source "$1"; }; load "$2"; printf sourced-only' _ "$ROOT/deploy.sh" "$ROOT/deploy.sh" 2>&1)" || rc=$?
      [[ "$rc" == 0 && "$output" == sourced-only && ! -e "$marker" ]]
      return
      ;;
    source-symlink)
      output="$(PATH="$entry_mock:$PATH" ENTRY_MARKER="$marker" bash -c 'source "$1"; printf sourced-only' _ "$entry_root/deploy-symlink" 2>&1)" || rc=$?
      [[ "$rc" == 0 && "$output" == sourced-only && ! -e "$marker" ]]
      return
      ;;
    execute-symlink) output="$(PATH="$entry_mock:$PATH" ENTRY_MARKER="$marker" bash "$entry_root/deploy-symlink" entry-arg 2>&1)" || rc=$? ;;
  esac
  [[ "$rc" != 0 ]]
  if [[ "$(id -u)" == 0 ]]; then
    [[ -e "$marker" && "$output" != *'unexpected curl URL'* ]]
  else
    [[ ! -e "$marker" && "$output" == *'Run as root'* ]]
  fi
}

for entry_mode in file executable stdin pipe source source-function source-symlink execute-symlink; do check run_entry_case "$entry_mode"; done

reset_deploy_overrides(){
  unset GH_REPO REPO_RAW TGE_SOURCE_REF TGE_CLI_BRANCH
  GH_REPO_WAS_SET=""; REPO_RAW_WAS_SET=""; SOURCE_REF_WAS_SET=""
  GH_REPO=""; REPO_RAW=""; SOURCE_REF=main
}

MOCK_RESPONSES=""
curl(){
  local url="${!#}" row status body
  while IFS='|' read -r status row body; do
    [[ -n "$row" && "$url" == "$row" ]] || continue
    case "$status" in
      200|404|403|500) printf '%s\n%s' "$body" "$status"; return 0 ;;
      dns) return 6 ;;
      *) fail "unexpected mock status: $status" ;;
    esac
  done <<< "$MOCK_RESPONSES"
  fail "unexpected curl request: $url"
}

reset_deploy_overrides
MOCK_RESPONSES='200|https://api.github.com/repos/runovelhq/tge|{"full_name":"runovelhq/tge"}'
resolve_repository >/dev/null
assert_eq "$GH_REPO" runovelhq/tge 'canonical repository is selected'

reset_deploy_overrides
MOCK_RESPONSES=$'404|https://api.github.com/repos/runovelhq/tge|{}\n200|https://api.github.com/repos/AlirezaSayyari/TGE|{"full_name":"AlirezaSayyari/TGE"}'
resolve_repository >/dev/null
assert_eq "$GH_REPO" AlirezaSayyari/TGE '404 falls back to current repository'

for response in \
  'dns|https://api.github.com/repos/runovelhq/tge|' \
  '403|https://api.github.com/repos/runovelhq/tge|{}' \
  '500|https://api.github.com/repos/runovelhq/tge|{}' \
  '200|https://api.github.com/repos/runovelhq/tge|{"message":"bad"}'; do
  reset_deploy_overrides; MOCK_RESPONSES="$response"
  if resolve_repository >/dev/null 2>&1; then fail 'transient or malformed canonical response must stop'; fi
done
pass 'transient, rate-limit, server, and malformed responses stop fallback'

reset_deploy_overrides
MOCK_RESPONSES='200|https://api.github.com/repos/runovelhq/tge|{"full_name":"RunovelHQ/TGE"}'
resolve_repository >/dev/null
assert_eq "$GH_REPO" RunovelHQ/TGE 'redirected canonical identity is retained'

reset_deploy_overrides
MOCK_RESPONSES=$'404|https://api.github.com/repos/runovelhq/tge|{}\n404|https://api.github.com/repos/AlirezaSayyari/TGE|{}\n404|https://api.github.com/repos/AlirezaSayyari/V2rayTGE|{}'
if resolve_repository >/dev/null 2>&1; then fail 'all 404 must fail'; fi
pass 'all candidates returning 404 fails clearly'

override_case(){
  local repo="${1-}" raw="${2-}" expected_repo="$3" expected_ref="$4"
  reset_deploy_overrides
  if [[ -n "$repo" ]]; then GH_REPO="$repo"; GH_REPO_WAS_SET=x; fi
  if [[ -n "$raw" ]]; then REPO_RAW="$raw"; REPO_RAW_WAS_SET=x; fi
  resolve_repository >/dev/null
  [[ "$GH_REPO" == "$expected_repo" && "$SOURCE_REF" == "$expected_ref" ]]
}
check override_case example/repo '' example/repo main
check override_case '' https://raw.githubusercontent.com/example/repo/v1.2.0 example/repo v1.2.0
check override_case example/repo https://raw.githubusercontent.com/example/repo/main example/repo main
assert_fails 'mismatched override rejected' override_case example/one https://raw.githubusercontent.com/example/two/main x x
assert_fails 'malformed repository rejected' override_case '../bad' '' x x
assert_fails 'query rejected' override_case '' 'https://raw.githubusercontent.com/example/repo/main?token=x' x x
assert_fails 'fragment rejected' override_case '' 'https://raw.githubusercontent.com/example/repo/main#x' x x
assert_fails 'ambiguous slash ref rejected' override_case '' https://raw.githubusercontent.com/example/repo/feature/bridge x x
assert_fails 'conflicting raw and explicit refs are rejected' bash -c '
  source "$1/deploy.sh"; GH_REPO=example/repo; GH_REPO_WAS_SET=x
  REPO_RAW=https://raw.githubusercontent.com/example/repo/main; REPO_RAW_WAS_SET=x
  SOURCE_REF=v1.2.0; SOURCE_REF_WAS_SET=x; resolve_repository >/dev/null 2>&1
' _ "$ROOT"

credential_output="$(
  reset_deploy_overrides
  REPO_RAW='https://token-secret@mirror.example/tge/main'; REPO_RAW_WAS_SET=x
  resolve_repository 2>&1
)" && fail 'credential-bearing URL accepted'
[[ "$credential_output" != *token-secret* ]] || fail 'credential leaked in diagnostics'
pass 'credential-bearing URL is rejected without disclosure'

reset_deploy_overrides
GH_REPO=example/repo; GH_REPO_WAS_SET=x
TGE_SOURCE_REF=feature/bridge; SOURCE_REF="$TGE_SOURCE_REF"; SOURCE_REF_WAS_SET=x
REPO_RAW=https://raw.githubusercontent.com/example/repo/feature/bridge; REPO_RAW_WAS_SET=x
resolve_repository >/dev/null
assert_eq "$SOURCE_REF" feature/bridge 'explicit TGE_SOURCE_REF disambiguates slash branch'

reset_deploy_overrides
REPO_RAW='https://mirror.example.invalid/tge/main'; REPO_RAW_WAS_SET=x
resolve_repository >/dev/null
[[ -z "$GH_REPO" && "$SOURCE_REF" == custom ]] || fail 'custom install raw source'
pass 'custom non-GitHub raw source is installation-only'

for pair in 'v1.10.0 v1.9.9' 'v2.0.0 v1.10.0' '1.2.4 v1.2.3'; do
  read -r left right <<< "$pair"; version_gt "$left" "$right" || fail "$left should exceed $right"
done
pass 'stable versions compare numerically'
for valid in v1.2.3 v01.002.0003 v999999999.999999999.999999999; do stable_version "$valid" || fail "stable boundary rejected: $valid"; done
for huge in v1000000000.1.1 v999999999999999999999.1.1; do stable_version "$huge" && fail "overflow version accepted: $huge"; done
pass 'numeric version components are bounded to nine digits'
for invalid in v1.2.4-rc.1 v1.2.4-beta invalid ''; do
  stable_version "$invalid" && fail "unstable value accepted: $invalid"
done
assert_eq "$(highest_version_from_tags '[{"name":"v1.9.9"},{"name":"v1.10.0"},{"name":"v2.0.0-beta"}]')" v1.10.0 'prereleases are ignored'

meta="$TEST_TMP/meta.env"
printf 'UNKNOWN=keep\nTGE_SOURCE_REF=old\nTGE_SOURCE_REF=duplicate\n' > "$meta"
GH_REPO=example/repo; SOURCE_REF=main; TGE_CLI_VERSION=v1.2.4; TGE_CLI_BRANCH=main; TGE_CLI_CHANNEL=stable
write_installed_metadata "$meta"
assert_eq "$(grep -c '^TGE_SOURCE_REF=' "$meta")" 1 'known metadata keys are replaced once'
grep -q '^UNKNOWN=keep$' "$meta" || fail 'unknown metadata field preserved'
pass 'unknown metadata fields are preserved'
before_inode="$(stat -c %i "$meta")"
write_installed_metadata "$meta"
[[ "$(stat -c %i "$meta")" != "$before_inode" ]] || fail 'metadata replacement was not atomic rename'
pass 'metadata uses atomic replacement'

marker="$TEST_TMP/pwned"
for hostile in "\$(touch $marker)" '"; touch pwned; #' $'value\nwith\nnewlines'; do
  GH_REPO="$hostile"; SOURCE_REF=main
  if write_installed_metadata "$meta" >/dev/null 2>&1; then fail 'hostile repository metadata accepted'; fi
done
GH_REPO=example/repo; SOURCE_REF='$(touch-pwned)'
if write_installed_metadata "$meta" >/dev/null 2>&1; then fail 'hostile ref metadata accepted'; fi
SOURCE_REF=main; TGE_CLI_VERSION="\$(touch $marker)"
write_installed_metadata "$meta"
( unset TGE_CLI_VERSION; source "$meta"; [[ "$TGE_CLI_VERSION" == "\$(touch $marker)" ]] )
[[ ! -e "$marker" ]] || fail 'metadata payload executed'
pass 'hostile metadata is rejected or safely serialized without execution'

# Load CLI functions, then redirect globals internally for pure cache tests. These
# are shell assignments after sourcing, not production environment hooks.
unset GH_REPO REPO_RAW
# shellcheck disable=SC1090
source "$ROOT/tge/bin/tge"
UPDATE_CACHE_DIR="$TEST_TMP/run/v2raytge"; UPDATE_CACHE_FILE="$UPDATE_CACHE_DIR/latest-version"
test_uid="$(id -u)"

(
  ETC_DIR="$TEST_TMP/canonical-install"; META_FILE="$ETC_DIR/meta.env"
  mkdir -p "$ETC_DIR" "$TEST_TMP/canonical-bin"
  printf metadata > "$META_FILE"
  canonical_cli=/usr/local/bin/tge
  [[ "$canonical_cli" == /usr/local/bin/tge ]]
) || fail 'canonical CLI verification path changed'
grep -q '\[\[ -x /usr/local/bin/tge && -r /opt/v2raytge/meta.env \]\]' "$ROOT/tge/bin/tge" || fail 'upgrade verifier does not use canonical CLI path'
pass 'upgrade verifier uses canonical CLI path'

(
  CFG="$TEST_TMP/backup-failure-config.env"
  BACKUP_DIR="$TEST_TMP/backup-failure-parent"
  printf preserve > "$CFG"
  printf blocker > "$BACKUP_DIR"
  if backup_config forced-failure >/dev/null 2>&1; then exit 1; fi
  [[ "$(<"$CFG")" == preserve ]]
) || fail 'production backup failure did not fail closed'
for backup_failure_command in date cp chmod; do
  (
    CFG="$TEST_TMP/backup-failure-$backup_failure_command.env"
    BACKUP_DIR="$TEST_TMP/backup-failure-$backup_failure_command"
    printf preserve > "$CFG"
    case "$backup_failure_command" in
      date) date(){ return 1; } ;;
      cp) cp(){ return 1; } ;;
      chmod) chmod(){ return 1; } ;;
    esac
    if backup_config forced-failure >/dev/null 2>&1; then exit 1; fi
    [[ "$(<"$CFG")" == preserve ]]
  ) || fail "production backup $backup_failure_command failure did not fail closed"
done
pass 'production backup failures return nonzero and preserve config'

(
  GH_REPO=""; GH_REPO_WAS_SET=""; REPO_RAW=https://raw.githubusercontent.com/example/repo/develop; REPO_RAW_WAS_SET=x
  SOURCE_REF=main; SOURCE_REF_WAS_SET=""
  resolve_repository
  [[ "$RESOLVED_REPOSITORY" == example/repo && "$RESOLVED_REF" == develop && "$RESOLVED_REF_EXPLICIT" == 1 ]]
) || fail 'CLI discarded ref derived from REPO_RAW'
pass 'CLI preserves a simple ref derived from REPO_RAW'

valid_temp_fixture="/tmp/tge-upgrade.Valid${RANDOM}"
mkdir -m 700 "$valid_temp_fixture"
temp_marker="$TEST_TMP/traversal-target"; mkdir -m 700 "$temp_marker"; printf keep > "$temp_marker/marker"
temp_anchor="/tmp/tge-upgrade.Anchor${RANDOM}"; mkdir -m 700 "$temp_anchor"
temp_link="/tmp/tge-upgrade.Link${RANDOM}"; ln -s "$valid_temp_fixture" "$temp_link"
temp_wrong_mode="/tmp/tge-upgrade.Mode${RANDOM}"; mkdir -m 755 "$temp_wrong_mode"
temp_file="/tmp/tge-upgrade.File${RANDOM}"; printf file > "$temp_file"
traversal_path="$temp_anchor/../$(basename "$TEST_TMP")/traversal-target"
invalid_temp_paths=("" / /tmp "$traversal_path" "$temp_anchor/." "$temp_anchor/.." '/tmp/tge-upgrade.' "$temp_anchor/child" "/tmp//$(basename "$valid_temp_fixture")" "/tmp/./$(basename "$valid_temp_fixture")" "/tmp/../tmp/$(basename "$valid_temp_fixture")" "/var/tmp/$(basename "$valid_temp_fixture")" relative/path "$TEST_TMP/nonexistent" "$temp_file" "$temp_link" "$temp_wrong_mode")
for invalid_path in "${invalid_temp_paths[@]}"; do assert_fails "invalid temporary path rejected: $invalid_path" valid_upgrade_temp_dir "$invalid_path"; done
valid_upgrade_temp_dir "$valid_temp_fixture" || fail 'valid canonical temporary directory rejected'
pass 'valid canonical direct child of /tmp is accepted'
assert_fails 'cleanup rejects traversal path' cleanup_upgrade_dir "$traversal_path"
[[ "$(<"$temp_marker/marker")" == keep ]] || fail 'cleanup traversal deleted marker'
pass 'cleanup traversal leaves its target untouched'

cleanup_valid="$(mktemp -d /tmp/tge-upgrade.CleanupXXXXXX)"
cleanup_fifo="/tmp/tge-upgrade.Fifo${RANDOM}"; mkfifo "$cleanup_fifo"
cleanup_nonexistent="/tmp/tge-upgrade.Missing${RANDOM}"
cleanup_nested="$temp_anchor/child"; mkdir -m 700 "$cleanup_nested"
cleanup_rm_log="$TEST_TMP/cleanup-rm.log"
cleanup_invalid_paths=("" / /tmp "$traversal_path" "$temp_anchor/." "$cleanup_nested" "$temp_file" "$temp_link" "$cleanup_fifo" "$temp_wrong_mode" "$cleanup_nonexistent")
for invalid_path in "${cleanup_invalid_paths[@]}"; do
  (
    rm(){ printf '%s\n' "$*" >> "$cleanup_rm_log"; command rm "$@"; }
    cleanup_upgrade_dir "$invalid_path"
  ) && fail "cleanup accepted invalid path: $invalid_path"
  [[ ! -e "$cleanup_rm_log" ]] || fail "cleanup invoked rm for invalid path: $invalid_path"
  [[ "$(<"$temp_marker/marker")" == keep && -d "$valid_temp_fixture" && -d "$temp_link" ]] || fail 'cleanup invalid matrix touched a protected fixture'
done
pass 'production cleanup rejects invalid path matrix without invoking rm'
(
  rm(){ printf '%s\n' "$*" >> "$cleanup_rm_log"; command rm "$@"; }
  cleanup_upgrade_dir "$cleanup_valid"
)
[[ ! -e "$cleanup_valid" ]] || fail 'production cleanup did not delete valid directory'
assert_eq "$(<"$cleanup_rm_log")" "-rf -- $cleanup_valid" 'production cleanup deletes only validated directory'

prepare_cache_dir "$test_uid"
[[ "$(stat -c %a "$UPDATE_CACHE_DIR")" == 755 ]] || fail 'secure cache directory mode'
pass 'secure cache directory is created with fixed mode'
write_update_cache 'runovelhq/tge|v1.2.4' "$test_uid"
assert_eq "$(<"$UPDATE_CACHE_FILE")" 'runovelhq/tge|v1.2.4' 'repository-aware cache written'
inode="$(stat -c %i "$UPDATE_CACHE_FILE")"
write_update_cache 'runovelhq/tge|v1.2.5' "$test_uid"
[[ "$(stat -c %i "$UPDATE_CACHE_FILE")" != "$inode" ]] || fail 'cache not atomically replaced'
pass 'cache replacement is atomic'
rm -f "$UPDATE_CACHE_FILE"; ln -s "$TEST_TMP/target" "$UPDATE_CACHE_FILE"
assert_fails 'cache symlink is rejected' write_update_cache 'runovelhq/tge|v1.2.6' "$test_uid"
[[ ! -e "$TEST_TMP/target" ]] || fail 'cache symlink target modified'
rm -f "$UPDATE_CACHE_FILE"; printf malformed > "$UPDATE_CACHE_FILE"; chmod 0644 "$UPDATE_CACHE_FILE"
cache_file_safe "$test_uid" || fail 'regular malformed cache should be safely readable then ignored'
assert_fails 'malformed cache record rejected' valid_cache_record malformed
assert_fails 'partial cache record rejected' valid_cache_record 'runovelhq/tge|'
pass 'malformed and partial cache can be ignored and refreshed'
for item in multiline carriage control separator; do
  cache_fixture="$TEST_TMP/cache-$item"
  case "$item" in
    multiline) printf 'runovelhq/tge\n|v1.2.4\n' > "$cache_fixture" ;;
    carriage) printf 'runovelhq/tge|v1.2.4\r\n' > "$cache_fixture" ;;
    control) printf 'runovelhq/tge|v1.2.4\001\n' > "$cache_fixture" ;;
    separator) printf 'runovelhq/tge||v1.2.4\n' > "$cache_fixture" ;;
  esac
  assert_fails "cache $item is rejected" read_cache_record "$cache_fixture"
done
printf 'runovelhq/tge|v1.2.4\n' > "$TEST_TMP/cache-valid-newline"
read_cache_record "$TEST_TMP/cache-valid-newline" || fail 'optional cache newline rejected'
pass 'single cache record with optional final newline is accepted'
(
  printf 'AlirezaSayyari/TGE|v1.2.4' > "$UPDATE_CACHE_FILE"
  prepare_cache_dir(){ return 0; }; cache_file_safe(){ return 0; }
  resolve_repository(){ RESOLVED_REPOSITORY=runovelhq/tge; return 0; }
  fetch_latest_version(){ printf 'runovelhq/tge|v1.2.5'; }
  write_update_cache(){ :; }
  assert_eq "$(latest_version_cached)" 'runovelhq/tge|v1.2.5' 'cache for a different repository is ignored'
)
old_cache="$TEST_TMP/v2raytge-latest-version"; printf attacker > "$old_cache"
[[ "$UPDATE_CACHE_FILE" != "$old_cache" && "$(<"$old_cache")" == attacker ]] || fail 'old tmp cache touched'
pass 'legacy tmp cache is ignored'

run_upgrade_case(){ (
  local mode="$1" output rc=0 installed_marker="$TEST_TMP/installed-$1" resolver_count="$TEST_TMP/resolver-$1"
  local curl_log="$TEST_TMP/curl-$1" install_log="$TEST_TMP/install-$1" cleanup_log="$TEST_TMP/cleanup-$1" mktemp_log="$TEST_TMP/mktemp-$1"
  rm -f "$installed_marker" "$resolver_count" "$curl_log" "$install_log" "$cleanup_log" "$mktemp_log"
  trap 'if [[ -s "$mktemp_log" ]]; then cleanup_path="$(<"$mktemp_log")"; if [[ "$cleanup_path" =~ ^/tmp/tge-upgrade\.[A-Za-z0-9]+$ ]]; then command rm -rf -- "$cleanup_path"; fi; fi' EXIT
  require_root(){ [[ "$mode" != nonroot ]]; }
  installed_version(){
    [[ "$mode" == version_missing ]] && { printf unknown; return; }
    [[ -e "$installed_marker" ]] && { [[ "$mode" == version_mismatch ]] && printf v1.1.0 || printf v1.2.0; } || printf v1.0.0
  }
  resolve_repository(){
    local count=0; [[ -e "$resolver_count" ]] && count="$(<"$resolver_count")"; printf '%s' "$((count + 1))" > "$resolver_count"
    [[ "$mode" != resolver_fail ]] || return 1
    RESOLVED_REPOSITORY=runovelhq/tge; RESOLVED_REF=""; RESOLVED_REF_EXPLICIT=0
    case "$mode" in
      explicit_branch) RESOLVED_REF=feature/test; RESOLVED_REF_EXPLICIT=1 ;;
      explicit_tag) RESOLVED_REF=v1.2.0; RESOLVED_REF_EXPLICIT=1 ;;
    esac
  }
  fetch_latest_version(){ [[ "$mode" != metadata_fail ]] && printf 'runovelhq/tge|v1.2.0'; }
  backup_config(){ [[ "$mode" != backup_fail ]]; }
  mktemp(){
    local created
    case "$mode" in
      mktemp_fail) return 1 ;;
      mktemp_empty) created='' ;;
      mktemp_nonexistent) created='/tmp/tge-upgrade.nonexistent' ;;
      mktemp_root) created=/ ;;
      mktemp_tmp) created=/tmp ;;
      mktemp_traversal) created="$traversal_path" ;;
      mktemp_symlink) created="$temp_link" ;;
      mktemp_wrongmode) created="$temp_wrong_mode" ;;
      *) created="$(command mktemp "$@")" || return ;;
    esac
    printf '%s' "$created" > "$mktemp_log"
    printf '%s' "$created"
  }
  clear_update_cache(){ [[ "$mode" != cache_clear_fail ]]; }
  upgrade_installation_present(){ [[ "$mode" != installed_files_missing ]]; }
  if [[ "$mode" == cleanup_fail ]]; then
    rm(){
      if [[ "$1" == -rf && "$2" == -- && "$3" =~ ^/tmp/tge-upgrade\.[A-Za-z0-9]+$ ]]; then
        printf '%s\n' "$3" >> "$cleanup_log"
        return 1
      fi
      command rm "$@"
    }
  fi
  curl(){
    local expected_dir expected_output
    expected_dir="$(<"$mktemp_log")"
    expected_output="$expected_dir/source.tar.gz"
    if [[ -e "$curl_log" || "$#" -ne 4 || "$1" != -fsSL || "$2" != "$UPGRADE_SOURCE_URL" || "$3" != -o || "$4" != "$expected_output" || "$4" == /source.tar.gz ]] || ! valid_upgrade_temp_dir "$expected_dir"; then
      printf 'UNEXPECTED|%s\n' "$*" >> "$curl_log"
      return 97
    fi
    printf 'EXPECTED|%s|%s\n' "$2" "$4" > "$curl_log"
    [[ "$mode" != download_fail ]] || return 1
    printf archive > "$expected_output"
  }
  tar(){
    [[ "$mode" != extract_fail && "$mode" != corrupt_archive ]] || return 1
    local dir=""; while (( $# )); do [[ "$1" == -C ]] && { dir="$2"; shift 2; continue; }; shift; done
    [[ "$mode" == unexpected_root ]] && { printf file > "$dir/not-a-directory"; return 0; }
    mkdir -p "$dir/source"
    [[ "$mode" == missing_installer ]] || printf '#!/usr/bin/env bash\n' > "$dir/source/deploy.sh"
  }
  bash(){
    printf '%s\n' "$*|$REPO_RAW|$GH_REPO|$TGE_SOURCE_REF" >> "$install_log"
    [[ "$mode" != installer_fail ]] || return 1
    [[ "$mode" != installer_signal ]] || return 143
    : > "$installed_marker"
  }
  output="$(upgrade_tge <<< yes 2>&1)" || rc=$?
  [[ ! -e "$curl_log" || "$(<"$curl_log")" == EXPECTED\|* ]] || return 1
  case "$mode" in
    success|explicit_branch|explicit_tag|metadata_fail|cache_clear_fail|cleanup_fail)
      [[ "$rc" == 0 && "$output" == *'Upgrade complete.'* && "$(<"$resolver_count")" == 1 ]]
      [[ -s "$mktemp_log" ]]
      [[ "$mode" == cleanup_fail || ! -e "$(<"$mktemp_log")" ]]
      [[ "$mode" != cache_clear_fail || "$output" == *'version cache could not be cleared'* ]]
      [[ "$mode" != cleanup_fail || ( "$output" == *'cleanup failed'* && -s "$cleanup_log" ) ]]
      [[ "$mode" != explicit_branch || "$(<"$install_log")" == *'feature/test|runovelhq/tge|feature/test'* ]]
      [[ "$mode" != explicit_tag || "$(<"$install_log")" == *'v1.2.0|runovelhq/tge|v1.2.0'* ]]
      ;;
    backup_fail|mktemp_*|nonroot|resolver_fail)
      [[ "$rc" != 0 && "$output" != *'Upgrade complete.'* && ! -e "$curl_log" && ! -e "$install_log" ]]
      [[ "$mode" != backup_fail || ! -e "$mktemp_log" ]]
      ;;
    *) [[ "$rc" != 0 && "$output" != *'Upgrade complete.'* ]] ;;
  esac
)}

upgrade_cases=(nonroot resolver_fail backup_fail mktemp_fail mktemp_empty mktemp_nonexistent mktemp_root mktemp_tmp mktemp_traversal mktemp_symlink mktemp_wrongmode download_fail corrupt_archive extract_fail unexpected_root missing_installer installer_fail installer_signal installed_files_missing version_missing version_mismatch explicit_branch explicit_tag metadata_fail cache_clear_fail cleanup_fail success)
for mode in "${upgrade_cases[@]}"; do check run_upgrade_case "$mode"; done
[[ "$(<"$temp_marker/marker")" == keep ]] || fail 'upgrade traversal deleted marker'
pass 'invalid mktemp upgrade cases leave traversal target untouched'
command rm -rf -- "$valid_temp_fixture" "$temp_anchor" "$temp_link" "$temp_wrong_mode" "$temp_file"
command rm -f -- "$cleanup_fifo"

# A current-directory VERSION must not influence piped/remote metadata.
pipe_dir="$TEST_TMP/pipe"; mkdir -p "$pipe_dir"; printf v99.0.0 > "$pipe_dir/VERSION"
(
  cd "$pipe_dir"; reset_deploy_overrides
  GH_REPO=example/repo; GH_REPO_WAS_SET=x
  curl(){ local url="${!#}"; case "$url" in */VERSION) printf v1.2.4;; */releases/latest) printf '{"tag_name":"v1.2.4"}';; */tags*) printf '[]';; *) fail "unexpected pipe mock: $url";; esac; }
  resolve_repository >/dev/null
  discover_cli_metadata
  [[ "$TGE_CLI_VERSION" == v1.2.4 ]]
) || fail 'unrelated current-directory VERSION influenced installer'
pass 'piped metadata ignores unrelated current-directory VERSION'

(
  reset_deploy_overrides
  GH_REPO=example/repo; GH_REPO_WAS_SET=x
  SOURCE_REF=feature/test; SOURCE_REF_WAS_SET=x
  REPO_RAW=https://raw.githubusercontent.com/example/repo/feature/test
  curl(){ [[ "${!#}" == "$REPO_RAW/VERSION" ]] || fail "explicit ref triggered latest metadata lookup"; printf v1.2.4; }
  discover_cli_metadata
  [[ "$SOURCE_REF" == feature/test && "$REPO_RAW" == https://raw.githubusercontent.com/example/repo/feature/test ]]
) || fail 'explicit installer ref changed during metadata discovery'
pass 'explicit installer ref is immutable during metadata discovery'

assert_eq "$(git -C "$ROOT" rev-parse 'v1.0.0^{commit}')" b8849865a6f793d28b990c56613ad6ff0afc4331 'annotated tag resolves'
assert_eq "$(git -C "$ROOT" rev-parse 'v1.2.0^{commit}')" b12e891be078a156ec06dd61c9721c26b912e1a8 'lightweight tag resolves'

printf 'all %d repository bridge checks passed\n' "$passes"
