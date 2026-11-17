#!/usr/bin/env bash
set -eo pipefail

VARIANT="${KERNELSU_VARIANT}"

case "$VARIANT" in
  "SukiSU") REPO="SukiSU-Ultra/SukiSU-Ultra"; KSUM="manager"; EXPECTED_BRANCH="main" ;;
  "BakaSU") REPO="Baka-SU/BakaSU";           KSUM="manager"; EXPECTED_BRANCH="main" ;;
  "FinaSU") REPO="LyraVoid/FinaSU";          KSUM="manager"; EXPECTED_BRANCH="master" ;;
  "KernelSU") REPO="tiann/KernelSU";          KSUM="manager"; EXPECTED_BRANCH="main" ;;
  *) echo "::error::Unknown variant: $VARIANT"; exit 1 ;;
esac

# Fallback channel parsing in case the selection step fails
CHANNEL_KIND="${CHANNEL_KIND:-}"
if [ -z "$CHANNEL_KIND" ]; then
  case "${BUILD_CHANNEL}" in
    Latest*|latest*|HEAD*) CHANNEL_KIND="latest" ;;
    *)                   CHANNEL_KIND="release" ;;
  esac
fi

mkdir -p manager-artifacts

# ==================== A. Stable channel: official Release manager ====================
if [ "${MANAGER_SOURCE:-ci}" = "release" ] && [ -n "${REL_APK_URL:-}" ]; then
  echo "Stable channel: downloading manager $REL_APK_NAME from Release $REL_TAG..."
  REL_APK="manager-artifacts/$(basename "$REL_APK_NAME")"
  if curl -sL --fail --retry 3 --max-time 300 -o "$REL_APK" "$REL_APK_URL"; then
    # Strip the ABI suffix before extracting the version so digits such as "_64" in x86_64 are not mistaken for the versionCode
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

      # Version consistency check: the KSU version at the Release tag commit should match the manager versionCode
      REL_COUNT=$(git -C KernelSU rev-list --count "$REL_COMMIT" 2>/dev/null || echo "")
      if [ -n "$REL_COUNT" ]; then
        case "$VARIANT" in
          SukiSU) REL_KSU_VERSION=$((40000 + REL_COUNT - 2815)) ;;
          BakaSU) REL_KSU_VERSION=$((30700 + REL_COUNT)) ;;
          FinaSU) REL_KSU_VERSION=$((30000 + REL_COUNT)) ;;
          KernelSU) REL_KSU_VERSION=$((30000 + REL_COUNT)) ;;
        esac
        if [ "$MANAGER_VERSION" != "$REL_KSU_VERSION" ]; then
          echo "::warning::Release manager version $MANAGER_VERSION does not match the KSU version $REL_KSU_VERSION at the tag commit"
        fi
      fi

      if [ "$VARIANT" == "FinaSU" ]; then
        echo "Extracting signing certificate from the Release manager APK..."
        CERT_INFO=$(python3 "$GITHUB_WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$REL_APK" | head -n1)
        if [ -n "$CERT_INFO" ]; then
          CERT_SIZE=$(echo "$CERT_INFO" | awk '{print $1}')
          CERT_HASH=$(echo "$CERT_INFO" | awk '{print $2}')
          echo "managerCertSize=$CERT_SIZE" >> $GITHUB_OUTPUT
          echo "managerCertHash=$CERT_HASH" >> $GITHUB_OUTPUT
          echo "Release manager certificate size=$CERT_SIZE sha256=$CERT_HASH"
        else
          echo "::warning title=Certificate missing::Could not extract the signing certificate from the Release manager APK; the kernel build will fall back to extracting it"
        fi
      fi
      exit 0
    fi
    echo "::warning title=Stable channel fallback::Could not parse the version from the Release manager filename ($(basename "$REL_APK")); falling back to the Latest channel"
  else
    echo "::warning title=Stable channel fallback::Failed to download the Release manager; falling back to the Latest channel"
  fi
  rm -rf manager-artifacts && mkdir -p manager-artifacts
fi

# ==================== B. FinaSU: Stable channel Release manager ====================
if [ "$VARIANT" == "FinaSU" ] && [ "${PIN_MODE:-pin}" != "head" ]; then
  # Stable channel (including fallback when no stable Release is available):
  #   Get the manager/certificate from the latest Release APK and pin the kernel to the Release tag commit
  #   The Latest channel uses the CI manager artifact from build-manager.yml below
  echo "FinaSU: fetching the manager from the latest Release APK..."
  REL_JSON=""
  for ATTEMPT in 1 2 3; do
    REL_JSON=$(curl -s --fail --max-time 30 \
      -H "Authorization: token ${GH_TOKEN}" \
      "https://api.github.com/repos/LyraVoid/FinaSU/releases/latest") \
      && [ -n "$REL_JSON" ] && break
    echo "Failed to fetch Release information; retrying ($ATTEMPT/3)..."
    REL_JSON=""
    sleep 5
  done
  if [ -z "$REL_JSON" ]; then
    echo "::warning::Could not fetch the latest FinaSU Release; skipping manager and certificate alignment for this run (kernel follows master)"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  REL_TAG=$(printf '%s' "$REL_JSON" | jq -r '.tag_name')
  REL_APK_URL=$(printf '%s' "$REL_JSON" | jq -r '.assets[] | select(.name | endswith(".apk")) | .browser_download_url' | head -n1)
  if [ -z "$REL_APK_URL" ] || [ "$REL_APK_URL" = "null" ]; then
    echo "::warning::Release $REL_TAG has no APK asset; skipping manager and certificate alignment for this run"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  echo "Downloading Release manager: $REL_TAG"
  REL_APK="manager-artifacts/$(basename "$REL_APK_URL")"
  if ! curl -sL --fail --retry 3 --max-time 300 -o "$REL_APK" "$REL_APK_URL"; then
    echo "::warning::Failed to download the Release manager; skipping manager and certificate alignment for this run"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  CLEAN_NAME=$(basename "$REL_APK" | sed -E 's/-(arm64-v8a|armeabi-v7a|armv7|riscv64|x86_64|x86|universal)-release\.apk$/.apk/')
  MANAGER_VERSION=$(echo "$CLEAN_NAME" | grep -oE '_[0-9]+' | tail -n 1 | tr -d '_')
  if ! [[ "${MANAGER_VERSION:-}" =~ ^[0-9]+$ ]]; then
    echo "::warning::Could not parse the version from the Release APK filename ($(basename "$REL_APK")); skipping manager and certificate alignment for this run"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  echo "Extracting signing certificate from the Release manager APK..."
  CERT_INFO=$(python3 "$GITHUB_WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$REL_APK" | head -n1)
  if [ -z "$CERT_INFO" ]; then
    echo "::warning::Could not extract the signing certificate from the Release manager APK; the kernel build will fall back to extracting it"
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
  # Latest: pin to master HEAD (the kernel is built from that commit); Stable: pin to the Release tag commit
  if [ "${PIN_MODE:-pin}" = "head" ]; then
    FINASU_REF=$(git -C KernelSU rev-parse "origin/master^{commit}" 2>/dev/null \
      || git ls-remote https://github.com/LyraVoid/FinaSU.git refs/heads/master 2>/dev/null | awk '{print $1}')
  else
    FINASU_REF=$(git -C KernelSU rev-parse "${REL_TAG}^{commit}" 2>/dev/null \
      || git ls-remote https://github.com/LyraVoid/FinaSU.git "refs/tags/${REL_TAG}^{}" 2>/dev/null | awk '{print $1}')
  fi
  echo "Kernel pinned to commit: ${FINASU_REF:0:8}"
  echo "ksuCommit=$FINASU_REF" >> $GITHUB_OUTPUT
  exit 0
fi

get_manager_artifacts() {
  local artifacts="$1"
  if [ "$VARIANT" == "FinaSU" ]; then
    # The official distribution artifact from build-manager.yml is always manager;
    # manager-gradle is an intermediate artifact that is not re-signed, so its certificate does not match the kernel second trust slot.
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

# The version uses the same source as manager versionCode (commit count + offset) and is used to select builds by version
ksu_version_of() {
  case "$1" in
    SukiSU) echo $((40000 + $2 - 2815)) ;;
    BakaSU) echo $((30700 + $2)) ;;
    FinaSU) echo $((30000 + $2)) ;;
    KernelSU) echo $((30000 + $2)) ;;
  esac
}

# Latest channel: pin the default-branch HEAD first, then select a manager build whose version matches that HEAD,
# avoiding version mismatches such as kernel 35249 / manager 35248.
# BakaSU/FinaSU exception: do not pin the default-branch HEAD; use build-manager.yml builds ordered by creation time
# and select the latest successful build, pinning the kernel to its commit so the manager and kernel versions match exactly.
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
    echo "::warning::Could not resolve $EXPECTED_BRANCH HEAD; selecting the manager from the latest build"
  fi
fi

# Following BakaSU_CI: fetch only Manager builds uploaded (push event) on the official default branch,
# and use the versionCode parsed from the downloaded APK filename to ensure the package name matches its contents
# Note: the runs-list API sorting/cache is unreliable in some repositories and may miss the latest build;
# the created-date filter uses a reliable query path, so search backward from today in date windows
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
  echo "Searching for Manager builds from $FROM through $TODAY..."
  for PAGE in 1 2 3; do
    RUNS=""
    for ATTEMPT in 1 2 3; do
      RUNS=$(curl -s --fail --max-time 30 -H "Authorization: token ${GH_TOKEN}" \
        "$RUNS_BASE&created=$FROM..$TODAY&per_page=30&page=$PAGE") && [ -n "$RUNS" ] && break
      echo "Failed to query the build list; retrying ($ATTEMPT/3)..."
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
      # Stable channel: accept only builds uploaded on the official default branch (push and workflow_dispatch are both allowed;
      # manual runs are often used for pre-release testing); skip PR and other-branch builds
      # (main for SukiSU/BakaSU, master for FinaSU)
      # Latest channel: accept builds from any branch except PR builds, then sort by version and HEAD match
      if [ "${PIN_MODE:-pin}" = "head" ]; then
        if [ "$EVENT" != "push" ] && [ "$EVENT" != "workflow_dispatch" ]; then
          echo "Skipping build $BUILD_ID ($CAND_BRANCH/$EVENT): not triggered by push or manual dispatch"
          continue
        fi
      elif [ "$CAND_BRANCH" != "$EXPECTED_BRANCH" ] || { [ "$EVENT" != "push" ] && [ "$EVENT" != "workflow_dispatch" ]; }; then
        echo "Skipping build $BUILD_ID ($CAND_BRANCH/$EVENT): not on the official $EXPECTED_BRANCH branch"
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
  echo "No usable Manager build was found."
  echo "ksuCommit=" >> $GITHUB_OUTPUT
  exit 1
fi

# Deduplicate and sort:
#   Stable → default-branch builds in reverse chronological order
#   Latest → prefer builds matching the HEAD version, then the default branch, then other branches (each group in reverse chronological order)
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
    echo "Prefer build commit ${PREF_SHA:0:8}, which matches HEAD version $HEAD_VERSION"
  fi
fi

ORDERED_FILE=$(mktemp)
if [ "$LATEST_PICK_BUILD" = 1 ]; then
  # Latest channel: strictly sort by build time and select the latest successful build from build-manager.yml
  sort -t$'\t' -k1,1r "$CAND_UNIQ" \
    | awk -F'\t' '{ print "0\t" $0 }' > "$ORDERED_FILE"
else
  # Candidate row format: created time \t build ID \t commit \t branch (priority is added as the first column by awk)
  sort -t$'\t' -k1,1r "$CAND_UNIQ" \
    | awk -F'\t' -v pref="$PREF_SHA" -v br="$EXPECTED_BRANCH" \
        '{ p = (pref != "" && $3 == pref) ? 0 : ($4 == br ? 1 : 2); print p "\t" $0 }' \
    | sort -t$'\t' -k1,1n -k2,2r > "$ORDERED_FILE"
fi
rm -f "$CAND_UNIQ"

CAND_COUNT=$(wc -l < "$ORDERED_FILE")
echo "Found $CAND_COUNT usable builds; trying them in priority order (using the version parsed from each APK filename)..."

MANAGER_VERSION=""
MANAGER_BUILD_ID=""
MANAGER_HEAD_SHA=""
MANAGER_BRANCH=""
MANAGER_APK=""
while IFS=$'\t' read -r PRIO CREATED BUILD_ID CAND_SHA CAND_BRANCH; do
  ARTIFACTS=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/repos/$REPO/actions/runs/$BUILD_ID/artifacts")
  CANDIDATE_LIST=$(get_manager_artifacts "$ARTIFACTS")
  if [ -z "$CANDIDATE_LIST" ]; then
    echo "Skipping build $BUILD_ID ($CAND_BRANCH, $CREATED): no artifact containing '$KSUM' was found"
    continue
  fi

  echo "Downloading artifacts from build $BUILD_ID ($CAND_BRANCH, $CREATED, ${CAND_SHA:0:8})..."
  rm -rf manager-artifacts
  mkdir -p manager-artifacts
  while IFS=$'\t' read -r NAME URL; do
    SAFE_NAME=$(echo "$NAME" | tr '/ ' '__')
    if ! curl -sL --fail -H "Authorization: token ${GH_TOKEN}" \
      -o "manager-artifacts/$SAFE_NAME.zip" "$URL"; then
      echo "Failed to download $NAME"
      continue
    fi
    mkdir -p "manager-artifacts/$SAFE_NAME"
    unzip -oq "manager-artifacts/$SAFE_NAME.zip" -d "manager-artifacts/$SAFE_NAME" || echo "Failed to extract $NAME"
    rm -f "manager-artifacts/$SAFE_NAME.zip"
  done <<< "$CANDIDATE_LIST"

  # Extract the measured versionCode from the APK filename for artifact naming
  # Prefer the arm64-v8a release (BakaSU downstream retains only this ABI)
  APK_FILE=$(find manager-artifacts -type f -name "*-arm64-v8a-release.apk" | head -n 1)
  if [ -z "$APK_FILE" ]; then
    APK_FILE=$(find manager-artifacts -type f -name "*release.apk" ! -name "*debug*" | head -n 1)
  fi
  if [ -z "$APK_FILE" ]; then
    echo "Skipping build $BUILD_ID ($CAND_BRANCH, $CREATED): no release APK in the artifact"
    continue
  fi
  # Strip the ABI suffix before extracting the version so digits such as "_64" in x86_64 are not mistaken for the versionCode
  CLEAN_NAME=$(basename "$APK_FILE" | sed -E 's/-(arm64-v8a|armeabi-v7a|armv7|riscv64|x86_64|x86|universal)-release\.apk$/.apk/')
  ACTUAL_VERSION=$(echo "$CLEAN_NAME" | grep -oE '_[0-9]+' | tail -n 1 | tr -d '_')
  if ! [[ "$ACTUAL_VERSION" =~ ^[0-9]+$ ]]; then
    echo "Skipping build $BUILD_ID ($CAND_BRANCH, $CREATED): could not parse the version from the APK filename ($(basename "$APK_FILE"))"
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
  echo "No usable Manager artifact was retrieved."
  echo "ksuCommit=" >> $GITHUB_OUTPUT
  exit 1
fi
echo "Selected Manager build $MANAGER_BUILD_ID ($MANAGER_BRANCH, ${MANAGER_HEAD_SHA:0:8}); APK measured version $MANAGER_VERSION"
# Kernel commit pinning strategy:
#   Stable → pin to that build commit (version exactly matches the manager)
#   Latest → pin to the default-branch HEAD at selection time (the manager was matched to that version)
PIN_COUNT=$(git -C KernelSU rev-list --count "$MANAGER_HEAD_SHA" 2>/dev/null || echo "")
if [ -n "$PIN_COUNT" ]; then
  case "$VARIANT" in
    BakaSU) PINNED_KSU_VERSION=$((30700 + PIN_COUNT)) ;;
    SukiSU) PINNED_KSU_VERSION=$((40000 + PIN_COUNT - 2815)) ;;
    FinaSU) PINNED_KSU_VERSION=$((30000 + PIN_COUNT)) ;;
    KernelSU) PINNED_KSU_VERSION=$((30000 + PIN_COUNT)) ;;
    *)      PINNED_KSU_VERSION="" ;;
  esac
  if [ -n "$PINNED_KSU_VERSION" ]; then
    echo "Manager build commit ${MANAGER_HEAD_SHA:0:8} corresponds to KSU version: $PINNED_KSU_VERSION"
    if [ "$MANAGER_VERSION" != "$PINNED_KSU_VERSION" ]; then
      echo "::warning::Manager measured version $MANAGER_VERSION does not match the KSU version $PINNED_KSU_VERSION for the build commit"
    fi
  elif [ -n "${KSU_VERSION:-}" ] && [ "$MANAGER_VERSION" != "$KSU_VERSION" ]; then
    echo "::warning::Manager measured version $MANAGER_VERSION does not match kernel KSU version ${KSU_VERSION}"
  fi
elif [ -n "${KSU_VERSION:-}" ] && [ "$MANAGER_VERSION" != "$KSU_VERSION" ]; then
  echo "::warning::Manager measured version $MANAGER_VERSION does not match kernel KSU version ${KSU_VERSION} (could not calculate the version for the build commit)"
fi
echo "MANAGER_VERSION=$MANAGER_VERSION" >> $GITHUB_ENV
echo "managerVer=$MANAGER_VERSION" >> $GITHUB_OUTPUT

if [ "$VARIANT" == "FinaSU" ]; then
  echo "Extracting signing certificate from the CI manager APK..."
  CERT_INFO=$(python3 "$GITHUB_WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$MANAGER_APK" | head -n1)
  if [ -n "$CERT_INFO" ]; then
    CERT_SIZE=$(echo "$CERT_INFO" | awk '{print $1}')
    CERT_HASH=$(echo "$CERT_INFO" | awk '{print $2}')
    echo "managerCertSize=$CERT_SIZE" >> $GITHUB_OUTPUT
    echo "managerCertHash=$CERT_HASH" >> $GITHUB_OUTPUT
    echo "CI manager certificate size=$CERT_SIZE sha256=$CERT_HASH"
  else
    echo "::warning title=Certificate missing::Could not extract the signing certificate from the CI manager APK; the kernel build will fall back to extracting it from the Release APK"
  fi
fi

if [ "${PIN_MODE:-pin}" = "head" ] && [ -n "$HEAD_SHA" ] && [ "$LATEST_PICK_BUILD" = 0 ]; then
  if [ -n "$HEAD_VERSION" ] && [ "$MANAGER_VERSION" != "$HEAD_VERSION" ]; then
    echo "::warning::Latest channel: no manager matching $EXPECTED_BRANCH HEAD version $HEAD_VERSION was found; falling back to $MANAGER_VERSION"
  fi
  echo "Latest channel: kernel pinned to $EXPECTED_BRANCH HEAD ${HEAD_SHA:0:8}, manager version $MANAGER_VERSION"
  echo "ksuCommit=$HEAD_SHA" >> $GITHUB_OUTPUT
else
  if [ "${PIN_MODE:-pin}" = "head" ] && [ "$LATEST_PICK_BUILD" = 1 ]; then
    echo "Latest channel: kernel pinned to build-manager commit ${MANAGER_HEAD_SHA:0:8}, manager version $MANAGER_VERSION"
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
    echo "BakaSU arm64-v8a release manager was not found."
    exit 1
  fi
  find manager-artifacts -type f -name "*.apk" -print
fi

