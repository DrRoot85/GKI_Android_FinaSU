#!/usr/bin/env bash
set -eo pipefail
VARIANT="$KSU_VARIANT"

case "$VARIANT" in
  "SukiSU-Nova") REPO="SukiSU-Nova/SukiSU-Nova"; KSUM="manager"; EXPECTED_BRANCH="main" ;;
  "BakaSU") REPO="Baka-SU/BakaSU";           KSUM="manager"; EXPECTED_BRANCH="main" ;;
  "FinaSU") REPO="LyraVoid/FinaSU";          KSUM="manager"; EXPECTED_BRANCH="master" ;;
  *) echo "::error::Unknown variant: $VARIANT"; exit 1 ;;
esac

# Channel fallback resolution (so it can still be determined from the input if the selection step misbehaves)
CHANNEL_KIND="${CHANNEL_KIND:-}"
if [ -z "$CHANNEL_KIND" ]; then
  case "$BUILD_CHANNEL" in
    Latest*|latest*|HEAD*) CHANNEL_KIND="latest" ;;
    *)                   CHANNEL_KIND="release" ;;
  esac
fi

mkdir -p manager-artifacts

# ==================== A. Release channel: official Release manager ====================
if [ "${MANAGER_SOURCE:-ci}" = "release" ] && [ -n "${REL_APK_URL:-}" ]; then
  echo "Release channel: downloading the manager of Release $REL_TAG ($REL_APK_NAME)..."
  REL_APK="manager-artifacts/$(basename "$REL_APK_NAME")"
  if curl -sL --fail --retry 3 --max-time 300 -o "$REL_APK" "$REL_APK_URL"; then
    # Strip the ABI segment before extracting the version, so numeric tails such as "_64" of x86_64 are not mistaken for the versionCode
    CLEAN_NAME=$(basename "$REL_APK" | sed -E 's/-(arm64-v8a|armeabi-v7a|armv7|riscv64|x86_64|x86|universal)-release\.apk$/.apk/')
    MANAGER_VERSION=$(echo "$CLEAN_NAME" | grep -oE '_[0-9]+' | tail -n 1 | tr -d '_')
    if [[ "${MANAGER_VERSION:-}" =~ ^[0-9]+$ ]]; then
      echo "Release manager version: $MANAGER_VERSION (tag $REL_TAG, commit ${REL_COMMIT:0:8})"
      echo "MANAGER_VERSION=$MANAGER_VERSION" >> $GITHUB_ENV
      {
        echo "managerVer=$MANAGER_VERSION"
        echo "ksuCommit=$REL_COMMIT"
        echo "channelTag=$REL_TAG"
      } >> $GITHUB_OUTPUT

      # Version consistency self-check: the KSU version of the Release tag commit should equal the manager versionCode
      REL_COUNT=$(git -C KernelSU rev-list --count "$REL_COMMIT" 2>/dev/null || echo "")
      if [ -n "$REL_COUNT" ]; then
        case "$VARIANT" in
          SukiSU-Nova) REL_KSU_VERSION=$((30000 + REL_COUNT - 4001)) ;;
          BakaSU) REL_KSU_VERSION=$((30700 + REL_COUNT)) ;;
          FinaSU) REL_KSU_VERSION=$((30000 + REL_COUNT)) ;;
        esac
        if [ "$MANAGER_VERSION" != "$REL_KSU_VERSION" ]; then
          echo "::warning::Release manager version $MANAGER_VERSION does not match the KSU version $REL_KSU_VERSION of the tag commit"
        fi
      fi

      if [ "$VARIANT" == "FinaSU" ]; then
        echo "Extracting the signing certificate from the Release manager APK..."
        CERT_INFO=$(python3 "$GITHUB_WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$REL_APK" | head -n1)
        if [ -n "$CERT_INFO" ]; then
          CERT_SIZE=$(echo "$CERT_INFO" | awk '{print $1}')
          CERT_HASH=$(echo "$CERT_INFO" | awk '{print $2}')
          echo "managerCertSize=$CERT_SIZE" >> $GITHUB_OUTPUT
          echo "managerCertHash=$CERT_HASH" >> $GITHUB_OUTPUT
          echo "Release manager certificate size=$CERT_SIZE sha256=$CERT_HASH"
        else
          echo "::warning title=Certificate missing::Cannot extract the signing certificate from the Release manager APK; the kernel side will fall back to extracting it"
        fi
      fi
      exit 0
    fi
    echo "::warning title=Release channel fallback::Cannot parse the version from the Release manager file name ($(basename "$REL_APK")); falling back to the Latest channel"
  else
    echo "::warning title=Release channel fallback::Failed to download the Release manager; falling back to the Latest channel"
  fi
  rm -rf manager-artifacts && mkdir -p manager-artifacts
fi

# ==================== B. FinaSU: Release channel Release manager ====================
if [ "$VARIANT" == "FinaSU" ] && [ "${PIN_MODE:-pin}" != "head" ]; then
  # Release channel (including the fallback when no stable Release is available):
  #   the manager/certificate come from the latest Release APK, and the kernel is pinned to the Release tag commit
  #   the Latest channel instead uses the CI manager artifacts of build-manager.yml below
  echo "FinaSU: taking the manager from the latest Release APK..."
  REL_JSON=""
  for ATTEMPT in 1 2 3; do
    REL_JSON=$(curl -s --fail --max-time 30 \
      -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/LyraVoid/FinaSU/releases/latest") \
      && [ -n "$REL_JSON" ] && break
    echo "Failed to fetch Release info, retrying ($ATTEMPT/3)..."
    REL_JSON=""
    sleep 5
  done
  if [ -z "$REL_JSON" ]; then
    echo "::warning::Cannot fetch the latest FinaSU Release info; skipping manager and certificate alignment this time (kernel follows master)"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  REL_TAG=$(printf '%s' "$REL_JSON" | jq -r '.tag_name')
  REL_APK_URL=$(printf '%s' "$REL_JSON" | jq -r '.assets[] | select(.name | endswith(".apk")) | .browser_download_url' | head -n1)
  if [ -z "$REL_APK_URL" ] || [ "$REL_APK_URL" = "null" ]; then
    echo "::warning::Release $REL_TAG has no APK asset; skipping manager and certificate alignment this time"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  echo "Downloading Release manager: $REL_TAG"
  REL_APK="manager-artifacts/$(basename "$REL_APK_URL")"
  if ! curl -sL --fail --retry 3 --max-time 300 -o "$REL_APK" "$REL_APK_URL"; then
    echo "::warning::Failed to download the Release manager; skipping manager and certificate alignment this time"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  CLEAN_NAME=$(basename "$REL_APK" | sed -E 's/-(arm64-v8a|armeabi-v7a|armv7|riscv64|x86_64|x86|universal)-release\.apk$/.apk/')
  MANAGER_VERSION=$(echo "$CLEAN_NAME" | grep -oE '_[0-9]+' | tail -n 1 | tr -d '_')
  if ! [[ "${MANAGER_VERSION:-}" =~ ^[0-9]+$ ]]; then
    echo "::warning::Cannot parse the version from the Release APK file name ($(basename "$REL_APK")); skipping manager and certificate alignment this time"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  echo "Extracting the signing certificate from the Release manager APK..."
  CERT_INFO=$(python3 "$GITHUB_WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$REL_APK" | head -n1)
  if [ -z "$CERT_INFO" ]; then
    echo "::warning::Could not extract the signing certificate from the Release manager APK; the kernel side will fall back to Release APK certificate extraction"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  CERT_SIZE=$(echo "$CERT_INFO" | awk '{print $1}')
  CERT_HASH=$(echo "$CERT_INFO" | awk '{print $2}')
  echo "Release: $REL_TAG, manager version $MANAGER_VERSION, certificate size=$CERT_SIZE sha256=$CERT_HASH"
  echo "MANAGER_VERSION=$MANAGER_VERSION" >> $GITHUB_ENV
  echo "managerVer=$MANAGER_VERSION" >> $GITHUB_OUTPUT
  echo "managerCertSize=$CERT_SIZE" >> $GITHUB_OUTPUT
  echo "managerCertHash=$CERT_HASH" >> $GITHUB_OUTPUT
  # Latest: pin master HEAD (the kernel is built at that commit); Release: pin the Release tag commit
  if [ "${PIN_MODE:-pin}" = "head" ]; then
    FINASU_REF=$(git -C KernelSU rev-parse "origin/master^{commit}" 2>/dev/null \
      || git ls-remote https://github.com/LyraVoid/FinaSU.git refs/heads/master 2>/dev/null | awk '{print $1}')
  else
    FINASU_REF=$(git -C KernelSU rev-parse "${REL_TAG}^{commit}" 2>/dev/null \
      || git ls-remote https://github.com/LyraVoid/FinaSU.git "refs/tags/${REL_TAG}^{}" 2>/dev/null | awk '{print $1}')
  fi
  echo "Kernel pinned commit: ${FINASU_REF:0:8}"
  echo "ksuCommit=$FINASU_REF" >> $GITHUB_OUTPUT
  exit 0
fi

# ---------- Latest channel: manager from the official CI build (SukiSU-Nova / BakaSU / FinaSU) ----------
get_manager_artifacts() {
  local artifacts="$1"
  if [ "$VARIANT" == "FinaSU" ]; then
    # The official distribution artifact of build-manager.yml is always named manager;
    # manager-gradle is an intermediate artifact that was not re-signed, and its certificate does not match the kernel's second trust slot.
    printf '%s' "$artifacts" | jq -r \
      '.artifacts[] | select(.name == "manager") | "\(.name)\t\(.archive_download_url)"'
  elif [ "$VARIANT" == "BakaSU" ]; then
    printf '%s' "$artifacts" | jq -r \
      '.artifacts[] | select(.name == "Manager-release" or .name == "Spoofed-Manager-release") | "\(.name)\t\(.archive_download_url)"'
  else
    printf '%s' "$artifacts" | jq -r --arg needle "$KSUM" \
      '.artifacts[] | select((.name | ascii_downcase) | contains($needle)) | "\(.name)\t\(.archive_download_url)"'
  fi
}

# The version number comes from the same source as the manager versionCode (commit count + offset), and is used to pick builds by version
ksu_version_of() {
  case "$1" in
    SukiSU-Nova) echo $((30000 + $2 - 4001)) ;;
    BakaSU) echo $((30700 + $2)) ;;
    FinaSU) echo $((30000 + $2)) ;;
  esac
}

# Latest channel: first pin the default branch HEAD, then restrict the manager to a build whose "version matches that HEAD",
# to avoid version mismatches such as kernel 35249 / manager 35248.
# BakaSU/FinaSU exception: do not pin the default branch HEAD; take the latest successful build of build-manager.yml
# sorted by creation time in descending order, and pin the kernel to that build commit, so the manager and kernel versions match exactly.
LATEST_PICK_BUILD=0
if [ "$VARIANT" = "BakaSU" ] || [ "$VARIANT" = "FinaSU" ]; then
  LATEST_PICK_BUILD=1
fi
HEAD_SHA=""
HEAD_VERSION=""
if [ "${PIN_MODE:-pin}" = "head" ] && [ "$LATEST_PICK_BUILD" = 0 ]; then
  HEAD_SHA=$(git -C KernelSU rev-parse "origin/${EXPECTED_BRANCH}^{commit}" 2>/dev/null || true)
  if [ -z "$HEAD_SHA" ]; then
    HEAD_SHA=$(git ls-remote "https://github.com/$REPO.git" "refs/heads/$EXPECTED_BRANCH" 2>/dev/null | awk '{print $1}')
  fi
  if [ -n "$HEAD_SHA" ]; then
    git -C KernelSU cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null || git -C KernelSU fetch -q origin "$HEAD_SHA" 2>/dev/null || true
    HEAD_COUNT=$(git -C KernelSU rev-list --count "$HEAD_SHA" 2>/dev/null || echo "")
    if [ -n "$HEAD_COUNT" ]; then
      HEAD_VERSION=$(ksu_version_of "$VARIANT" "$HEAD_COUNT")
    fi
    echo "Latest channel: $EXPECTED_BRANCH HEAD ${HEAD_SHA:0:8} corresponds to KSU version ${HEAD_VERSION:-Unknown}"
  else
    echo "::warning::Cannot resolve $EXPECTED_BRANCH HEAD; selecting the manager by the latest build"
  fi
fi

# Like BakaSU_CI: only fetch Manager builds that were most recently uploaded (push) to the official default branch,
# and name the artifact by the versionCode measured from the downloaded APK file name, so the package name matches its contents exactly
# Note: the sorting/caching of the runs list API is unreliable in some repositories (it may miss the latest build),
# while the created date filter parameter goes through a reliable query path, so search backwards from today in date windows
FILENAME="build-manager.yml"
RUNS_BASE="https://api.github.com/repos/$REPO/actions/workflows/$FILENAME/runs?status=success"
CAND_FILE=$(mktemp)
TODAY=$(date -u +%Y-%m-%d)

for DAYS in 0 7 30 90 365; do
  if [ "$DAYS" -eq 0 ]; then
    FROM="$TODAY"
  else
    FROM=$(date -u -d "today - $DAYS days" +%Y-%m-%d)
  fi
  echo "Searching Manager builds between $FROM and $TODAY..."
  for PAGE in 1 2 3; do
    RUNS=""
    for ATTEMPT in 1 2 3; do
      RUNS=$(curl -s --fail --max-time 30 -H "Authorization: token $GH_TOKEN" \
        "$RUNS_BASE&created=$FROM..$TODAY&per_page=30&page=$PAGE") && [ -n "$RUNS" ] && break
      echo "Failed to query the build list, retrying ($ATTEMPT/3)..."
      RUNS=""
      sleep 3
    done
    RUN_COUNT=$(printf '%s' "$RUNS" | jq '.workflow_runs | length')
    if [ "$RUN_COUNT" -eq 0 ]; then
      break
    fi
    for INDEX in $(seq 0 $((RUN_COUNT - 1))); do
      BUILD_ID=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].id")
      CAND_SHA=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].head_sha")
      CAND_BRANCH=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].head_branch")
      EVENT=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].event")
      CREATED=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].created_at")
      # Release channel: only accept builds uploaded to the official default branch (both push and workflow_dispatch work,
      # manual triggers are often used for pre-release testing before an official upload), and skip PR / other-branch builds
      # (main for SukiSU-Nova/BakaSU, master for FinaSU)
      # Latest channel: accept builds from any branch (skipping PR builds), then sort by version match with HEAD
      if [ "${PIN_MODE:-pin}" = "head" ]; then
        if [ "$EVENT" != "push" ] && [ "$EVENT" != "workflow_dispatch" ]; then
          echo "Skipping build $BUILD_ID ($CAND_BRANCH/$EVENT): not a push/manual-trigger build"
          continue
        fi
      elif [ "$CAND_BRANCH" != "$EXPECTED_BRANCH" ] || { [ "$EVENT" != "push" ] && [ "$EVENT" != "workflow_dispatch" ]; }; then
        echo "Skipping build $BUILD_ID ($CAND_BRANCH/$EVENT): not a build of the official $EXPECTED_BRANCH branch"
        continue
      fi
      printf '%s\t%s\t%s\t%s\n' "$CREATED" "$BUILD_ID" "$CAND_SHA" "$CAND_BRANCH" >> "$CAND_FILE"
    done
  done
  if [ -s "$CAND_FILE" ]; then
    break
  fi
done

if [ ! -s "$CAND_FILE" ]; then
  rm -f "$CAND_FILE"
  echo "No usable Manager build found."
  echo "ksuCommit=" >> $GITHUB_OUTPUT
  exit 1
fi

# Sort after deduplication:
#   Release -> default-branch builds in descending time order
#   Latest -> builds whose "version matches HEAD" first, then the default branch, then other branches (descending time order within each group)
CAND_UNIQ=$(mktemp)
sort -u -t$'\t' -k2,2 "$CAND_FILE" > "$CAND_UNIQ"
rm -f "$CAND_FILE"

PREF_SHA=""
if [ "${PIN_MODE:-pin}" = "head" ] && [ -n "$HEAD_VERSION" ]; then
  while IFS=$'\t' read -r CREATED BUILD_ID CAND_SHA CAND_BRANCH; do
    if [ "$CAND_SHA" = "$HEAD_SHA" ]; then
      PREF_SHA="$CAND_SHA"
      break
    fi
    git -C KernelSU cat-file -e "${CAND_SHA}^{commit}" 2>/dev/null \
      || git -C KernelSU fetch -q origin "$CAND_SHA" 2>/dev/null \
      || continue
    CAND_COUNT=$(git -C KernelSU rev-list --count "$CAND_SHA" 2>/dev/null || echo "")
    [ -n "$CAND_COUNT" ] || continue
    if [ "$(ksu_version_of "$VARIANT" "$CAND_COUNT")" = "$HEAD_VERSION" ]; then
      PREF_SHA="$CAND_SHA"
      break
    fi
  done < <(sort -t$'\t' -k1,1r "$CAND_UNIQ" | head -n 40)
  if [ -n "$PREF_SHA" ]; then
    echo "Preferring the build commit ${PREF_SHA:0:8} that matches HEAD version $HEAD_VERSION"
  fi
fi

ORDERED_FILE=$(mktemp)
if [ "$LATEST_PICK_BUILD" = 1 ]; then
  # Latest channel: strictly in descending build time order, take the latest successful build of build-manager.yml
  sort -t$'\t' -k1,1r "$CAND_UNIQ" \
    | awk -F'\t' '{ print "0\t" $0 }' > "$ORDERED_FILE"
else
  # Candidate row format: creation time \t build ID \t commit \t branch (the priority is added as column 1 in awk)
  sort -t$'\t' -k1,1r "$CAND_UNIQ" \
    | awk -F'\t' -v pref="$PREF_SHA" -v br="$EXPECTED_BRANCH" \
        '{ p = (pref != "" && $3 == pref) ? 0 : ($4 == br ? 1 : 2); print p "\t" $0 }' \
    | sort -t$'\t' -k1,1n -k2,2r > "$ORDERED_FILE"
fi
rm -f "$CAND_UNIQ"

CAND_COUNT=$(wc -l < "$ORDERED_FILE")
echo "Found $CAND_COUNT usable build(s); trying them one by one by priority (version measured from the APK file name)..."

MANAGER_VERSION=""
MANAGER_BUILD_ID=""
MANAGER_HEAD_SHA=""
MANAGER_BRANCH=""
MANAGER_APK=""
while IFS=$'\t' read -r PRIO CREATED BUILD_ID CAND_SHA CAND_BRANCH; do
  ARTIFACTS=$(curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/actions/runs/$BUILD_ID/artifacts")
  CANDIDATE_LIST=$(get_manager_artifacts "$ARTIFACTS")
  if [ -z "$CANDIDATE_LIST" ]; then
    echo "Skipping build $BUILD_ID ($CAND_BRANCH, $CREATED): no artifact containing '$KSUM' found"
    continue
  fi

  echo "Downloading artifacts of build $BUILD_ID ($CAND_BRANCH, $CREATED, ${CAND_SHA:0:8})..."
  rm -rf manager-artifacts
  mkdir -p manager-artifacts
  while IFS=$'\t' read -r NAME URL; do
    SAFE_NAME=$(echo "$NAME" | tr '/ ' '__')
    if ! curl -sL --fail -H "Authorization: token $GH_TOKEN" \
      -o "manager-artifacts/$SAFE_NAME.zip" "$URL"; then
      echo "Failed to download $NAME"
      continue
    fi
    mkdir -p "manager-artifacts/$SAFE_NAME"
    unzip -oq "manager-artifacts/$SAFE_NAME.zip" -d "manager-artifacts/$SAFE_NAME" || echo "Failed to unzip $NAME"
    rm -f "manager-artifacts/$SAFE_NAME.zip"
  done <<< "$CANDIDATE_LIST"

  # Extract the measured versionCode from the APK file name as the artifact name
  # Prefer the arm64-v8a release (BakaSU downstream keeps only this one ABI)
  APK_FILE=$(find manager-artifacts -type f -name "*-arm64-v8a-release.apk" | head -n 1)
  if [ -z "$APK_FILE" ]; then
    APK_FILE=$(find manager-artifacts -type f -name "*release.apk" ! -name "*debug*" | head -n 1)
  fi
  if [ -z "$APK_FILE" ]; then
    echo "Skipping build $BUILD_ID ($CAND_BRANCH, $CREATED): no release APK in the artifact"
    continue
  fi
  # Strip the ABI segment before extracting the version, so numeric tails such as "_64" of x86_64 are not mistaken for the versionCode
  CLEAN_NAME=$(basename "$APK_FILE" | sed -E 's/-(arm64-v8a|armeabi-v7a|armv7|riscv64|x86_64|x86|universal)-release\.apk$/.apk/')
  ACTUAL_VERSION=$(echo "$CLEAN_NAME" | grep -oE '_[0-9]+' | tail -n 1 | tr -d '_')
  if ! [[ "$ACTUAL_VERSION" =~ ^[0-9]+$ ]]; then
    echo "Skipping build $BUILD_ID ($CAND_BRANCH, $CREATED): cannot parse the version from the APK file name ($(basename "$APK_FILE"))"
    continue
  fi

  MANAGER_VERSION="$ACTUAL_VERSION"
  MANAGER_BUILD_ID="$BUILD_ID"
  MANAGER_HEAD_SHA="$CAND_SHA"
  MANAGER_BRANCH="$CAND_BRANCH"
  MANAGER_APK="$APK_FILE"
  break
done < "$ORDERED_FILE"
rm -f "$ORDERED_FILE"

if [ -z "$MANAGER_VERSION" ]; then
  echo "No usable Manager artifact obtained."
  echo "ksuCommit=" >> $GITHUB_OUTPUT
  exit 1
fi
echo "Selected Manager build $MANAGER_BUILD_ID ($MANAGER_BRANCH, ${MANAGER_HEAD_SHA:0:8}), APK measured version $MANAGER_VERSION"
# Kernel commit pinning strategy:
#   Release -> pin that build commit (version matches the manager exactly)
#   Latest -> pin the default branch HEAD at selection time (the manager was already matched to that version, so the two agree)
PIN_COUNT=$(git -C KernelSU rev-list --count "$MANAGER_HEAD_SHA" 2>/dev/null || echo "")
if [ -n "$PIN_COUNT" ]; then
  case "$VARIANT" in
    BakaSU) PINNED_KSU_VERSION=$((30700 + PIN_COUNT)) ;;
    SukiSU-Nova) PINNED_KSU_VERSION=$((30000 + PIN_COUNT - 4001)) ;;
    FinaSU) PINNED_KSU_VERSION=$((30000 + PIN_COUNT)) ;;
    *)      PINNED_KSU_VERSION="" ;;
  esac
  if [ -n "$PINNED_KSU_VERSION" ]; then
    echo "Manager build commit ${MANAGER_HEAD_SHA:0:8} corresponds to KSU version: $PINNED_KSU_VERSION"
    if [ "$MANAGER_VERSION" != "$PINNED_KSU_VERSION" ]; then
      echo "::warning::Manager measured version $MANAGER_VERSION does not match the KSU version $PINNED_KSU_VERSION of the build commit"
    fi
  elif [ -n "${KSU_VERSION:-}" ] && [ "$MANAGER_VERSION" != "$KSU_VERSION" ]; then
    echo "::warning::Manager measured version $MANAGER_VERSION does not match the kernel KSU version ${KSU_VERSION}"
  fi
elif [ -n "${KSU_VERSION:-}" ] && [ "$MANAGER_VERSION" != "$KSU_VERSION" ]; then
  echo "::warning::Manager measured version $MANAGER_VERSION does not match the kernel KSU version ${KSU_VERSION} (cannot compute the version of the build commit)"
fi
echo "MANAGER_VERSION=$MANAGER_VERSION" >> $GITHUB_ENV
echo "managerVer=$MANAGER_VERSION" >> $GITHUB_OUTPUT

if [ "$VARIANT" == "FinaSU" ]; then
  echo "Extracting the signing certificate from the CI manager APK..."
  CERT_INFO=$(python3 "$GITHUB_WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$MANAGER_APK" | head -n1)
  if [ -n "$CERT_INFO" ]; then
    CERT_SIZE=$(echo "$CERT_INFO" | awk '{print $1}')
    CERT_HASH=$(echo "$CERT_INFO" | awk '{print $2}')
    echo "managerCertSize=$CERT_SIZE" >> $GITHUB_OUTPUT
    echo "managerCertHash=$CERT_HASH" >> $GITHUB_OUTPUT
    echo "CI manager certificate size=$CERT_SIZE sha256=$CERT_HASH"
  else
    echo "::warning title=Certificate missing::Cannot extract the signing certificate from the CI manager APK; the kernel side will fall back to Release APK certificate extraction"
  fi
fi

if [ "${PIN_MODE:-pin}" = "head" ] && [ -n "$HEAD_SHA" ] && [ "$LATEST_PICK_BUILD" = 0 ]; then
  if [ -n "$HEAD_VERSION" ] && [ "$MANAGER_VERSION" != "$HEAD_VERSION" ]; then
    echo "::warning::Latest channel: no manager found whose version matches $EXPECTED_BRANCH HEAD version $HEAD_VERSION; falling back to $MANAGER_VERSION"
  fi
  echo "Latest channel: kernel pinned to $EXPECTED_BRANCH HEAD ${HEAD_SHA:0:8}, manager version $MANAGER_VERSION"
  echo "ksuCommit=$HEAD_SHA" >> $GITHUB_OUTPUT
else
  if [ "${PIN_MODE:-pin}" = "head" ] && [ "$LATEST_PICK_BUILD" = 1 ]; then
    echo "Latest channel: kernel pinned to the build-manager build commit ${MANAGER_HEAD_SHA:0:8}, manager version $MANAGER_VERSION"
  else
    echo "Kernel pinned to build commit ${MANAGER_HEAD_SHA:0:8}, manager version $MANAGER_VERSION"
  fi
  echo "ksuCommit=$MANAGER_HEAD_SHA" >> $GITHUB_OUTPUT
fi

if [ "$VARIANT" == "BakaSU" ]; then
  echo "Keeping only the BakaSU arm64-v8a release manager..."
  find manager-artifacts -type f -name "*.apk" ! -name "*-arm64-v8a-release.apk" -delete
  find manager-artifacts -type f -name "*debug*.apk" -delete
  if ! find manager-artifacts -type f -name "*-arm64-v8a-release.apk" | grep -q .; then
    echo "BakaSU arm64-v8a release manager not found."
    exit 1
  fi
  find manager-artifacts -type f -name "*.apk" -print
fi
