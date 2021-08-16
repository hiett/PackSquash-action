#!/bin/sh -e

readonly UNUSABLE_CACHE_ERROR_CODE=129

show_deprecated_warning() {
  printf '::warning::The %s option is deprecated and will be removed in the future. Please use %s instead.\n' "$1" "$2"
}

download_release_executable() {
  temp_file=$(mktemp)
  wget -q -O "$temp_file" "https://github.com/ComunidadAylas/PackSquash/releases/download/$1/$2"
  unzip -qo "$temp_file"
  rm -f "$temp_file"
}

# ----------------
# Check invariants
# ----------------

echo "Checking that the repository checkout at $GITHUB_WORKSPACE is suitable"
if [ "$(git -C "$GITHUB_WORKSPACE" rev-parse --is-shallow-repository)" = 'true' ]; then
  echo '::error::The full commit history of the repository must be checked out for this action to work. Please set the fetch-depth parameter of actions/checkout to 0.'
  exit 1
fi

# ------------------------
# Handle deprecated inputs
# ------------------------

if [ -n "${INPUT_SETTINGS_FILE+x}" ]; then
  show_deprecated_warning 'settings_file' 'options_file'

  INPUT_OPTIONS_FILE="$INPUT_SETTINGS_FILE"
fi

if [ -n "$INPUT_STRICT_ZIP_SPEC_COMPLIANCE" ]; then
  show_deprecated_warning 'strict_zip_spec_compliance' 'zip_spec_conformance_level'

  if [ "$INPUT_STRICT_ZIP_SPEC_COMPLIANCE" = 'true' ]; then
    INPUT_ZIP_SPEC_CONFORMANCE_LEVEL='high'
  else
    INPUT_ZIP_SPEC_CONFORMANCE_LEVEL='disregard'
  fi
fi

if [ -n "$INPUT_COMPRESS_ALREADY_COMPRESSED_FILES" ]; then
  show_deprecated_warning 'compress_already_compressed_files' 'recompress_compressed_files'

  INPUT_RECOMPRESS_COMPRESSED_FILES="$INPUT_COMPRESS_ALREADY_COMPRESSED_FILES"
fi

if [ -n "$INPUT_QUANTIZE_IMAGE" ]; then
  show_deprecated_warning 'quantize_image' 'image_color_quantization_target'

  if [ "$INPUT_QUANTIZE_IMAGE" = 'true' ]; then
    INPUT_IMAGE_COLOR_QUANTIZATION_TARGET='eight_bit_depth'
  else
    INPUT_IMAGE_COLOR_QUANTIZATION_TARGET='none'
  fi
fi

# ----------------------------------------------------------
# Handle options that need to be converted to another format
# ----------------------------------------------------------

# allow_mods
ALLOW_MODS='[ '
if [ "$INPUT_ALLOW_OPTIFINE_MOD" = 'true' ]; then
  ALLOW_MODS="$ALLOW_MODS'OptiFine'"
fi
ALLOW_MODS="$ALLOW_MODS ]"

# work_around_minecraft_quirks
WORK_AROUND_MINECRAFT_QUIRKS='[ '
if [ "$INPUT_WORK_AROUND_GRAYSCALE_TEXTURES_GAMMA_MISCORRECTION_QUIRK" = 'true' ]; then
  WORK_AROUND_MINECRAFT_QUIRKS="$WORK_AROUND_MINECRAFT_QUIRKS'grayscale_textures_gamma_miscorrection'"
  minecraft_quirk_added=
fi
if [ "$INPUT_WORK_AROUND_JAVA8_ZIP_OBFUSCATION_QUIRKS" = 'true' ]; then
  WORK_AROUND_MINECRAFT_QUIRKS="$WORK_AROUND_MINECRAFT_QUIRKS${minecraft_quirk_added+, }'java8_zip_obfuscation_quirks'"
  minecraft_quirk_added=
fi
WORK_AROUND_MINECRAFT_QUIRKS="$WORK_AROUND_MINECRAFT_QUIRKS ]"

# PACKSQUASH_SYSTEM_ID environment variable
export PACKSQUASH_SYSTEM_ID="$INPUT_SYSTEM_ID"

# ----------------------
# Flags based on options
# ----------------------

if
  [ -n "$INPUT_OPTIONS_FILE" ] || \
  { [ "$INPUT_NEVER_STORE_SQUASH_TIMES" = 'false' ] && [ "$INPUT_ZIP_SPEC_CONFORMANCE_LEVEL" != 'pedantic' ]; }
then
  cache_may_be_used=
fi

# ----------------------------------------------
# Download the appropriate PackSquash executable
# ----------------------------------------------

case "$INPUT_PACKSQUASH_VERSION" in
  'latest')
    if [ -z "$INPUT_GITHUB_TOKEN" ]; then
      echo '::error::A GitHub API token is needed to download the latest PackSquash build.'
      exit 1
    else
      latest_artifacts_endpoint=$(curl -sSL 'https://api.github.com/repos/ComunidadAylas/PackSquash/actions/runs?branch=master&status=completed' \
        | jq '.workflow_runs | map(select(.workflow_id == 5482008 && .conclusion == "success"))' \
        | jq -r 'sort_by(.updated_at) | reverse | .[0].artifacts_url')

      latest_artifact_download_url=$(curl -sSL "$latest_artifacts_endpoint" \
        | jq '.artifacts | map(select(.name == "PackSquash executable (Linux, x64, glibc)"))' \
        | jq -r '.[0].archive_download_url')

      temp_file=$(mktemp)
      wget --header="Authorization: token $INPUT_GITHUB_TOKEN" -q -O "$temp_file" "$latest_artifact_download_url"
      unzip -qo "$temp_file"
      rm -f "$temp_file"
    fi
  ;;
  'v0.1.0' | 'v0.1.1' | 'v0.1.2' | 'v0.2.0' | 'v0.2.1')
    if [ -z "$INPUT_OPTIONS_FILE" ]; then
      echo '::error::Using older PackSquash versions without an options file is not supported.'
      exit 1
    else
      if [ "$INPUT_PACKSQUASH_VERSION" = 'v0.3.0-rc.1' ]; then
        asset_name='PackSquash.executable.Linux.x64.glibc.zip'
      else
        asset_name='PackSquash.executable.Linux.zip'
      fi

      download_release_executable "$INPUT_PACKSQUASH_VERSION" "$asset_name"
    fi
  ;;
  *) # Another release that does not require any special handling
    download_release_executable "$INPUT_PACKSQUASH_VERSION" 'PackSquash.executable.Linux.x64.glibc.zip'
  ;;
esac

chmod +x packsquash

# Print PackSquash version
echo '::group::PackSquash version'
packsquash --version
echo '::endgroup::'

# ---------------------------
# Generate PackSquash options
# ---------------------------

if [ -z "$INPUT_OPTIONS_FILE" ]; then
  cat <<OPTIONS_FILE > current-packsquash-options.toml
pack_directory = '$INPUT_PATH'
skip_pack_icon = $INPUT_SKIP_PACK_ICON
recompress_compressed_files = $INPUT_RECOMPRESS_COMPRESSED_FILES
zip_compression_iterations = $INPUT_ZIP_COMPRESSION_ITERATIONS
work_around_minecraft_quirks = $WORK_AROUND_MINECRAFT_QUIRKS
ignore_system_and_hidden_files = $INPUT_IGNORE_SYSTEM_AND_HIDDEN_FILES
allow_mods = $ALLOW_MODS
zip_spec_conformance_level = '$INPUT_ZIP_SPEC_CONFORMANCE_LEVEL'
size_increasing_zip_obfuscation = $INPUT_SIZE_INCREASING_ZIP_OBFUSCATION
percentage_of_zip_structures_tuned_for_obfuscation_discretion = $INPUT_PERCENTAGE_OF_ZIP_STRUCTURES_TUNED_FOR_OBFUSCATION_DISCRETION
never_store_squash_times = $INPUT_NEVER_STORE_SQUASH_TIMES
output_file_path = '/pack.zip'

['**/*.{og[ga],mp3,wav,flac}']
transcode_ogg = $INPUT_TRANSCODE_OGG
sampling_frequency = $INPUT_SAMPLING_FREQUENCY
minimum_bitrate = $INPUT_MINIMUM_BITRATE
maximum_bitrate = $INPUT_MAXIMUM_BITRATE
target_pitch = $INPUT_TARGET_PITCH

['**/*.{json,jsonc}']
minify_json = $INPUT_MINIFY_JSON
delete_bloat_keys = $INPUT_DELETE_BLOAT_JSON_KEYS

['**/*.png']
image_data_compression_iterations = '$INPUT_IMAGE_DATA_COMPRESSION_ITERATIONS'
color_quantization_target = '$INPUT_IMAGE_COLOR_QUANTIZATION_TARGET'
maximum_width_and_height = $INPUT_MAXIMUM_IMAGE_WIDTH_AND_HEIGHT
skip_alpha_optimizations = $INPUT_SKIP_IMAGE_ALPHA_OPTIMIZATIONS

['**/*.{fsh,vsh}']
minify_shader = $INPUT_MINIFY_SHADERS

['**/*.properties']
minify_properties = $INPUT_MINIFY_PROPERTIES
OPTIONS_FILE
else
  cp "$GITHUB_WORKSPACE/$INPUT_OPTIONS_FILE" current-packsquash-options.toml
fi

echo '::group::PackSquash options'
nl -ba -nln current-packsquash-options.toml
echo '::endgroup::'

# -------------
# Restore cache
# -------------

# Restore /pack.zip, /system_id and /packsquash-options.toml from the cache if possible and useful
if [ -n "${cache_may_be_used+x}" ]; then
  echo 'Restoring cache'
  node actions-cache.js restore
fi

# Only override the system ID if the user didn't set it explicitly
if [ -z "$PACKSQUASH_SYSTEM_ID" ]; then
  PACKSQUASH_SYSTEM_ID=$(cat system_id 2>/dev/null || true)
fi

# Save whatever system ID we end up using for caching later
echo "$PACKSQUASH_SYSTEM_ID" > system_id
echo "::debug::Using system ID: $PACKSQUASH_SYSTEM_ID"

# Discard the cached ZIP file if the options have changed, to make sure they are completely honored
if ! cmp -s current-packsquash-options.toml packsquash-options.toml; then
  rm -f pack.zip
fi
mv current-packsquash-options.toml packsquash-options.toml

# -----------------
# Optimize the pack
# -----------------

cd "$GITHUB_WORKSPACE"

# Make sure the file modification times reflect when they were modified according to git,
# so the cache works as expected
if [ -n "${cache_may_be_used+x}" ]; then
  /git-set-file-times.pl
fi

# Run PackSquash
echo '::group::PackSquash output'
set +e
/packsquash /packsquash-options.toml
if [ $? -eq $UNUSABLE_CACHE_ERROR_CODE ]; then
  set -e
  echo
  echo 'PackSquash reported that the cache was unusable. Discarding it and trying again.'
  echo

  rm -f /pack.zip
  /packsquash /packsquash-options.toml
else
  set -e
fi
echo '::endgroup::'

# ------------------------------------
# Upload artifact and update the cache
# ------------------------------------

echo 'Uploading generated ZIP file as artifact'
node actions-artifact-upload.js

if [ -n "${cache_may_be_used+x}" ]; then
  echo 'Saving cache'
  node actions-cache.js save
fi
