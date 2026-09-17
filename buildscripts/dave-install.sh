#!/usr/bin/env bash
set -uo pipefail

# Dave's personal script: lives on daily-driver only, never merge upstream.
#
# Interactively builds NetNewsWire for macOS (Debug, like Xcode's Run, or
# Release) and installs it into /Applications, backing up the currently
# installed copy first.
#
# Usage:
#   buildscripts/dave-install.sh             build + install
#   buildscripts/dave-install.sh --rollback  restore a backed-up build
#
# Depends on gum <https://github.com/charmbracelet/gum> and xcbeautify.

# === CONFIGURABLE VARIABLES ===
PROJECT_PATH="NetNewsWire.xcodeproj"
SCHEME="NetNewsWire"
APP_NAME="NetNewsWire.app"
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME"
# Release builds use their own DerivedData; Debug builds share Xcode's so they stay incremental.
RELEASE_DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/NetNewsWire-dave-release"
BACKUP_DIR="$HOME/Library/Application Support/NetNewsWire Install Backups"
BACKUPS_TO_KEEP=5
LOG_DIR="$HOME/Library/Logs/NetNewsWire dave-install"
TESTFLIGHT_TAG_PREFIX="dave-testflight-"

# Colors (ANSI 256)
PINK=212
PURPLE=99
GREEN=42
YELLOW=214
RED=196
GREY=245

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

TIMING_ROWS=()
TOTAL_START=$SECONDS

# === HELPERS ===

die() {
	window_title "failed"
	gum style --foreground "$RED" --bold "✗ $*" >&2
	notify "NetNewsWire install failed" "$*"
	exit 1
}

info() {
	gum style --foreground "$GREY" "$*"
}

success() {
	gum style --foreground "$GREEN" "$*"
}

warn() {
	gum style --foreground "$YELLOW" "$*"
}

# Writes a terminal control sequence to the tty, wrapped for tmux passthrough if needed.
osc() {
	local sequence="\033]$1\007"
	if [[ -n "${TMUX:-}" ]]; then
		sequence="\033Ptmux;\033${sequence}\033\\"
	fi
	{ printf '%b' "$sequence" >/dev/tty; } 2>/dev/null || true
}

# Desktop notification via OSC 777 (Ghostty shows it when the window isn't focused).
notify() {
	# Semicolons delimit OSC 777 fields.
	osc "777;notify;${1//;/,};${2//;/,}"
}

# Window title via OSC 2. Terminals also show it as the notification subtitle.
window_title() {
	osc "2;🗞 NNW: $1"
}

# Terminal progress indicator via OSC 9;4. States: 0 clear, 2 error, 3 indeterminate.
progress() {
	osc "9;4;$1"
}

format_duration() {
	local total=$1
	if ((total >= 60)); then
		printf '%dm %02ds' $((total / 60)) $((total % 60))
	else
		printf '%ds' "$total"
	fi
}

plist_value() {
	/usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

app_version() {
	local app=$1
	if [[ ! -d "$app" ]]; then
		echo "not installed"
		return
	fi
	local config="Release"
	[[ "$(plist_value "$app" CFBundleIdentifier)" == *-DEBUG ]] && config="Debug"
	echo "$(plist_value "$app" CFBundleShortVersionString) ($(plist_value "$app" CFBundleVersion)) $config"
}

section() {
	echo
	gum style --foreground "$PURPLE" --bold "── $* ──"
}

# Runs a command while showing a live, rolling tail of its xcbeautify output
# in a bordered box. Full raw output goes to $LOG_DIR/<slug>.log.
# Usage: run_with_live_log "Title" slug command args...
run_with_live_log() {
	local title=$1
	local slug=$2
	shift 2

	mkdir -p "$LOG_DIR"
	local raw_log="$LOG_DIR/$slug.log"
	local pretty_log="$LOG_DIR/$slug.pretty.log"

	"$@" >"$raw_log" 2>&1 &
	local pid=$!

	local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
	local frame=0
	local start=$SECONDS
	local drawn=0
	local tail_lines=10

	tput civis 2>/dev/null
	progress 3
	window_title "$title"
	trap 'tput cnorm 2>/dev/null; progress 0; kill $pid 2>/dev/null; exit 130' INT TERM

	while kill -0 "$pid" 2>/dev/null; do
		local cols
		cols=$(tput cols 2>/dev/null || echo 100)
		local inner=$((cols - 6))
		((inner < 20)) && inner=20

		local header
		header=$(gum style --foreground "$PINK" --bold "${frames[frame]} $title  $(format_duration $((SECONDS - start)))")
		local body
		# xcbeautify buffers when not writing to a terminal, so beautify the raw log's tail each frame instead of streaming.
		body=$(tail -n 400 "$raw_log" | xcbeautify --disable-colored-output --disable-logging | tail -n "$tail_lines" | cut -c "1-$inner")
		local box
		# Fixed height so the box doesn't grow as output starts arriving.
		box=$(printf '%s\n%s' "$header" "$(gum style --foreground "$GREY" "$body")" |
			gum style --border rounded --border-foreground "$PURPLE" --padding "0 1" --width $((cols - 2)) --height $((tail_lines + 1)))

		if ((drawn > 0)); then
			tput cuu "$drawn"
			tput ed
		fi
		printf '%s\n' "$box"
		drawn=$(printf '%s\n' "$box" | grep -c '^')

		frame=$(((frame + 1) % ${#frames[@]}))
		sleep 0.25
	done

	wait "$pid"
	local status=$?
	local elapsed=$((SECONDS - start))

	trap - INT TERM
	tput cnorm 2>/dev/null
	progress 0
	if ((drawn > 0)); then
		tput cuu "$drawn"
		tput ed
	fi

	TIMING_ROWS+=("$title,$(format_duration "$elapsed"),$([[ $status -eq 0 ]] && echo ✅ || echo ❌)")

	if [[ $status -eq 0 ]]; then
		success "✓ $title ($(format_duration "$elapsed"))"
	else
		progress 2
		gum style --foreground "$RED" --bold "✗ $title failed after $(format_duration "$elapsed")"
		xcbeautify --disable-colored-output --disable-logging <"$raw_log" >"$pretty_log"
		local errors
		errors=$(grep -E '^\[x\]|✖' "$pretty_log" | head -n 20)
		[[ -z "$errors" ]] && errors=$(grep -E 'error:|FAILED' "$raw_log" | head -n 20)
		[[ -z "$errors" ]] && errors=$(tail -n 20 "$raw_log")
		if [[ -n "$errors" ]]; then
			gum style --border rounded --border-foreground "$RED" --padding "0 1" "$errors"
		fi
		info "Full log: $raw_log"
		print_timings
		die "$title failed"
	fi
}

print_timings() {
	((${#TIMING_ROWS[@]} == 0)) && return
	echo
	{
		for row in "${TIMING_ROWS[@]}"; do
			echo "$row"
		done
		echo "Total,$(format_duration $((SECONDS - TOTAL_START))),"
	} | gum table --print --columns "Step,Time,  " --border rounded --border.foreground "$PURPLE" --header.foreground "$PINK"
}

# === TESTFLIGHT STATUS ===

# Prints a one-line description of how HEAD relates to the dave-testflight-N tags on origin.
testflight_status() {
	local head_sha
	head_sha=$(git rev-parse HEAD)

	local source="origin"
	local tag_lines
	if ! tag_lines=$(git ls-remote --tags origin "refs/tags/${TESTFLIGHT_TAG_PREFIX}*" 2>/dev/null); then
		source="local tags (origin unreachable)"
		tag_lines=$(git for-each-ref --format='%(objectname) refs/tags/%(refname:short)' "refs/tags/${TESTFLIGHT_TAG_PREFIX}*" |
			while read -r _ ref; do echo "$(git rev-parse "$ref^{commit}") $ref"; done)
	fi

	# Build "N sha" pairs, one per tag, preferring the peeled commit sha.
	local pairs
	pairs=$(echo "$tag_lines" | awk -v prefix="refs/tags/${TESTFLIGHT_TAG_PREFIX}" '
		$2 ~ prefix {
			ref = $2
			peeled = sub(/\^\{\}$/, "", ref)
			n = substr(ref, length(prefix) + 1)
			if (n !~ /^[0-9]+$/) next
			if (peeled || !(n in sha)) sha[n] = $1
		}
		END { for (n in sha) print n, sha[n] }
	' | sort -n)

	if [[ -z "$pairs" ]]; then
		warn "☁️  No ${TESTFLIGHT_TAG_PREFIX}N tags found on $source"
		return
	fi

	local latest_n latest_sha
	read -r latest_n latest_sha <<<"$(echo "$pairs" | tail -n 1)"
	local latest_tag="${TESTFLIGHT_TAG_PREFIX}${latest_n}"

	local head_n
	head_n=$(echo "$pairs" | awk -v sha="$head_sha" '$2 == sha { n = $1 } END { print n }')

	if [[ "$head_sha" == "$latest_sha" ]]; then
		success "☁️  Sent to Xcode Cloud: HEAD is $latest_tag"
	elif [[ -n "$head_n" ]]; then
		warn "☁️  HEAD is ${TESTFLIGHT_TAG_PREFIX}${head_n}, but $latest_tag is newer"
	elif git merge-base --is-ancestor "$latest_sha" HEAD 2>/dev/null; then
		local ahead
		ahead=$(git rev-list --count "$latest_sha..HEAD")
		warn "☁️  Not on TestFlight: HEAD is $ahead commit(s) past $latest_tag"
	else
		local local_tag
		local_tag=$(git tag --points-at HEAD --list "${TESTFLIGHT_TAG_PREFIX}*" | head -n 1)
		if [[ -n "$local_tag" ]]; then
			warn "☁️  HEAD is tagged $local_tag locally, but that tag isn't on origin"
		else
			warn "☁️  Not on TestFlight: HEAD doesn't descend from $latest_tag"
		fi
	fi
	if [[ "$source" != "origin" ]]; then
		info "   (checked $source)"
	fi
}

# === ROLLBACK ===

rollback() {
	section "Rollback"
	local backups
	backups=$(list_backups | sort -r)
	[[ -n "$backups" ]] || die "No backups in $BACKUP_DIR"

	local choice
	choice=$(gum choose --header "Restore which build? (installed: $(app_version "$INSTALLED_APP"))" <<<"$backups") || exit 0
	[[ -n "$choice" ]] || exit 0

	gum confirm "Replace $INSTALLED_APP with $choice?" || exit 0
	check_install_permissions
	quit_running_app
	backup_installed_app
	$SUDO mv "$BACKUP_DIR/$choice" "$INSTALLED_APP" || die "Restore failed"
	success "✓ Restored $(app_version "$INSTALLED_APP")"
	prune_backups
	offer_launch
	exit 0
}

# === INSTALL STEPS ===

SUDO=""

check_install_permissions() {
	if [[ -w "$INSTALL_DIR" ]] && { [[ ! -e "$INSTALLED_APP" ]] || [[ -w "$INSTALLED_APP" ]]; }; then
		return
	fi
	warn "No write access to $INSTALL_DIR — sudo is needed to install."
	gum confirm "Use sudo?" || die "Can't install without write access"
	sudo -v || die "sudo failed"
	SUDO="sudo"
}

quit_running_app() {
	if ! pgrep -xq NetNewsWire; then
		return
	fi
	gum confirm "NetNewsWire is running. Quit it?" --affirmative "Quit it" --negative "Abort" || die "Aborted: NetNewsWire still running"

	osascript -e 'tell application "NetNewsWire" to quit' >/dev/null 2>&1
	local waited=0
	while pgrep -xq NetNewsWire && ((waited < 30)); do
		sleep 0.5
		waited=$((waited + 1))
	done
	if pgrep -xq NetNewsWire; then
		die "NetNewsWire didn't quit"
	fi
	success "✓ Quit NetNewsWire"
}

backup_installed_app() {
	[[ -d "$INSTALLED_APP" ]] || return

	mkdir -p "$BACKUP_DIR"
	# Timestamp first, so names sort chronologically.
	local backup
	backup="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S) NetNewsWire $(app_version "$INSTALLED_APP").app"

	$SUDO mv "$INSTALLED_APP" "$backup" || die "Couldn't move $INSTALLED_APP to backup"
	if [[ -n "$SUDO" ]]; then
		sudo chown -R "$(id -un)" "$backup"
	fi
	success "✓ Backed up installed app to $(basename "$backup")"
}

# Prints backup names, oldest first.
list_backups() {
	local path
	for path in "$BACKUP_DIR"/*.app; do
		[[ -d "$path" ]] && basename "$path"
	done
}

prune_backups() {
	local excess
	excess=$(($(list_backups | grep -c '^') - BACKUPS_TO_KEEP))
	((excess > 0)) || return 0
	list_backups | head -n "$excess" | while read -r old; do
		rm -rf "${BACKUP_DIR:?}/$old"
		info "  pruned old backup $old"
	done
}

offer_launch() {
	echo
	if gum confirm "Launch NetNewsWire?"; then
		open "$INSTALLED_APP"
	fi
}

verify_signature() {
	section "Signature"
	local details authority team
	details=$(codesign -dvv "$BUILT_APP" 2>&1)
	authority=$(echo "$details" | awk -F= '/^Authority=/ { print $2; exit }')
	team=$(echo "$details" | awk -F= '/^TeamIdentifier=/ { print $2; exit }')

	if codesign --verify --deep --strict "$BUILT_APP" 2>/dev/null; then
		success "✅ codesign verify passed"
	else
		warn "⚠️  codesign verify failed:"
		codesign --verify --deep --strict "$BUILT_APP" 2>&1 | sed 's/^/   /'
	fi
	info "   Authority: ${authority:-none (ad hoc?)}"
	info "   Team:      ${team:-none}"
	info "   Arch:      $(lipo -archs "$BUILT_APP/Contents/MacOS/NetNewsWire" 2>/dev/null)"

	if spctl --assess --type execute "$BUILT_APP" 2>/dev/null; then
		success "✅ Gatekeeper accepts it"
	else
		info "   Gatekeeper: not accepted (expected for a non-notarized local build)"
	fi
}

# === MAIN ===

case "${1:-}" in
-h | --help)
	sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
	;;
--rollback | "")
	;;
*)
	echo "Unknown option: $1" >&2
	exit 1
	;;
esac

for tool in gum xcbeautify; do
	command -v "$tool" >/dev/null || {
		echo "$tool is required: brew install $tool" >&2
		exit 1
	}
done

window_title "build"
gum style \
	--border double --border-foreground "$PINK" --foreground "$PINK" --bold \
	--align center --width 50 --padding "1 2" --margin "1 0" \
	"🗞  NetNewsWire" "Build → /Applications"

[[ "${1:-}" == "--rollback" ]] && rollback

# Pre-flight: git state
section "Source"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
SHORT_SHA=$(git rev-parse --short HEAD)
SUBJECT=$(git log -1 --format=%s)
DIRTY_COUNT=$(git status --porcelain | grep -c '^')

{
	echo "Branch:    $BRANCH"
	echo "Commit:    $SHORT_SHA $SUBJECT"
	if ((DIRTY_COUNT > 0)); then
		echo "Tree:      $DIRTY_COUNT uncommitted change(s)"
	else
		echo "Tree:      clean"
	fi
	echo "Installed: $(app_version "$INSTALLED_APP")"
} | gum style --border rounded --border-foreground "$PURPLE" --padding "0 1"

testflight_status

if ((DIRTY_COUNT > 0)); then
	git status --short | head -n 15 | gum style --foreground "$YELLOW" --margin "0 2"
	gum confirm "Working tree is dirty. Build anyway?" --default=false || exit 0
fi

if [[ ! -f "$REPO_ROOT/../SharedXcodeSettings/DeveloperSettings.xcconfig" ]]; then
	warn "⚠️  ../SharedXcodeSettings/DeveloperSettings.xcconfig not found; code signing will probably fail. Run ./setup.sh first."
fi

# Options
section "Options"
CONFIGURATION=$(gum choose --header "Configuration:" --selected Debug \
	"Debug" "Release") || exit 0
[[ -n "$CONFIGURATION" ]] || exit 0

if [[ "$CONFIGURATION" == "Debug" ]]; then
	{
		echo "Debug build caveats:"
		echo "• Share and Safari extensions are disabled (SKIP_APP_GROUP_ACCESS)"
		echo "• -DEBUG bundle ID: uses Xcode's Debug data, not the Release app's"
		echo "• Shares a database with Xcode's Run; don't run both at once"
		echo "• Unoptimized, and no refresh on launch"
	} | gum style --foreground "$YELLOW" --border rounded --border-foreground "$YELLOW" --padding "0 1"
fi

OPT_TESTS="Run tests first"
OPT_CLEAN="Clean build"
OPT_UNIVERSAL="Universal binary (arm64 + x86_64)"

CHOICES=$(gum choose --no-limit --header "x or Tab to toggle, Enter to go:" \
	--selected "$OPT_TESTS" \
	"$OPT_TESTS" "$OPT_CLEAN" "$OPT_UNIVERSAL") || exit 0

has_choice() {
	grep -qxF "$1" <<<"$CHOICES"
}

has_choice "$OPT_TESTS" && RUN_TESTS=1 || RUN_TESTS=0
has_choice "$OPT_CLEAN" && CLEAN=1 || CLEAN=0
has_choice "$OPT_UNIVERSAL" && UNIVERSAL=1 || UNIVERSAL=0

info "Config: $CONFIGURATION · Tests: $([[ $RUN_TESTS == 1 ]] && echo yes || echo no) · Clean: $([[ $CLEAN == 1 ]] && echo yes || echo no) · Arch: $([[ $UNIVERSAL == 1 ]] && echo universal || echo arm64)"

# Debug matches Xcode's Run on "My Mac": default DerivedData, no build setting overrides
# (overrides would make Xcode and this script invalidate each other's builds).
if [[ "$CONFIGURATION" == "Debug" ]]; then
	DERIVED_DATA_ARGS=()
	DESTINATION="platform=macOS,arch=arm64"
	ARCH_SETTINGS=()
	((UNIVERSAL)) && ARCH_SETTINGS=("ARCHS=arm64 x86_64" "ONLY_ACTIVE_ARCH=NO")
else
	DERIVED_DATA_ARGS=(-derivedDataPath "$RELEASE_DERIVED_DATA")
	DESTINATION="generic/platform=macOS"
	ARCH_SETTINGS=("ARCHS=arm64" "ONLY_ACTIVE_ARCH=NO")
	((UNIVERSAL)) && ARCH_SETTINGS=("ARCHS=arm64 x86_64" "ONLY_ACTIVE_ARCH=NO")
fi

# Test
section "Build"
if ((RUN_TESTS)); then
	run_with_live_log "Tests" tests \
		xcodebuild \
		-project "$PROJECT_PATH" \
		-scheme "$SCHEME" \
		-destination "platform=macOS,arch=arm64" \
		${DERIVED_DATA_ARGS[@]+"${DERIVED_DATA_ARGS[@]}"} \
		test
fi

# Build
BUILD_ACTIONS=(build)
((CLEAN)) && BUILD_ACTIONS=(clean build)

BUILD_ARGS=(
	-project "$PROJECT_PATH"
	-scheme "$SCHEME"
	-configuration "$CONFIGURATION"
	-destination "$DESTINATION"
	${DERIVED_DATA_ARGS[@]+"${DERIVED_DATA_ARGS[@]}"}
	${ARCH_SETTINGS[@]+"${ARCH_SETTINGS[@]}"}
)

run_with_live_log "$CONFIGURATION build" build \
	xcodebuild "${BUILD_ARGS[@]}" "${BUILD_ACTIONS[@]}"

BUILT_PRODUCTS_DIR=$(xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null |
	awk -F ' = ' '/^ *BUILT_PRODUCTS_DIR = / { print $2; exit }')
BUILT_APP="$BUILT_PRODUCTS_DIR/$APP_NAME"
[[ -n "$BUILT_PRODUCTS_DIR" && -d "$BUILT_APP" ]] || die "Build succeeded but couldn't find $APP_NAME (looked in '$BUILT_PRODUCTS_DIR')"

verify_signature

# Install
section "Install"
OLD_VERSION=$(app_version "$INSTALLED_APP")
NEW_VERSION=$(app_version "$BUILT_APP")
gum style --border rounded --border-foreground "$PINK" --padding "0 2" --align center \
	"$OLD_VERSION  →  $(gum style --foreground "$PINK" --bold "$NEW_VERSION")"

gum confirm "Install to $INSTALL_DIR?" || {
	info "Skipped install. Built app: $BUILT_APP"
	print_timings
	exit 0
}

INSTALL_START=$SECONDS
check_install_permissions
quit_running_app
backup_installed_app
gum spin --title "Copying to $INSTALL_DIR" -- $SUDO ditto "$BUILT_APP" "$INSTALLED_APP" || die "Copy to $INSTALL_DIR failed"
TIMING_ROWS+=("Install,$(format_duration $((SECONDS - INSTALL_START))),✅")
success "✓ Installed $(app_version "$INSTALLED_APP") to $INSTALL_DIR"
prune_backups

print_timings
window_title "done"
notify "NetNewsWire installed" "$NEW_VERSION from $SHORT_SHA"
gum style --foreground "$PINK" --bold --margin "1 0 0 0" "🎉 Done!"

offer_launch
