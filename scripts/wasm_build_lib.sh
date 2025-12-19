#!/usr/bin/env bash

set -euo pipefail

trap exit SIGINT

PROJECT_ROOT="$(cd $(dirname "$BASH_SOURCE[0]") && cd .. && pwd)" &> /dev/null

# Check Emscripten version - must be <= 3.1.50
# Emscripten 3.1.58+ removed the separate .worker.js file for pthreads,
# which breaks the COI threading build. See: https://github.com/emscripten-core/emscripten/pull/21701
# Additionally, versions 3.1.51-3.1.57 have binaryen version mismatches.
EMCC_VERSION=$(emcc --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
EMCC_MAJOR=$(echo "$EMCC_VERSION" | cut -d. -f1)
EMCC_MINOR=$(echo "$EMCC_VERSION" | cut -d. -f2)
EMCC_PATCH=$(echo "$EMCC_VERSION" | cut -d. -f3)

EMCC_TOO_NEW=false
if [ "$EMCC_MAJOR" -gt 3 ]; then
  EMCC_TOO_NEW=true
elif [ "$EMCC_MAJOR" -eq 3 ] && [ "$EMCC_MINOR" -gt 1 ]; then
  EMCC_TOO_NEW=true
elif [ "$EMCC_MAJOR" -eq 3 ] && [ "$EMCC_MINOR" -eq 1 ] && [ "$EMCC_PATCH" -gt 50 ]; then
  EMCC_TOO_NEW=true
fi

if [ "$EMCC_TOO_NEW" = true ]; then
  echo "ERROR: Emscripten version $EMCC_VERSION is too new."
  echo ""
  echo "This project requires Emscripten 3.1.50 or earlier."
  echo "Emscripten 3.1.58+ removed the separate .worker.js file for pthreads,"
  echo "which breaks the COI (Cross-Origin Isolation) threading build."
  echo "Versions 3.1.51-3.1.57 have binaryen version mismatches."
  echo ""
  echo "To install the correct version using emsdk:"
  echo "  git clone https://github.com/emscripten-core/emsdk.git"
  echo "  cd emsdk"
  echo "  ./emsdk install 3.1.50"
  echo "  ./emsdk activate 3.1.50"
  echo "  source ./emsdk_env.sh"
  echo ""
  echo "See: https://github.com/emscripten-core/emscripten/pull/21701"
  exit 1
fi

echo "Emscripten version: $EMCC_VERSION (OK)"

MODE=${1:-Fast}
FEATURES=${2:-mvp}
DUCKDB_LOCATION=${3:-"$PROJECT_ROOT/submodules/duckdb"}
echo "MODE=${MODE}"
echo "${DUCKDB_LOCATION}"

CPP_SOURCE_DIR="${PROJECT_ROOT}/lib"
DUCKDB_LIB_DIR="${PROJECT_ROOT}/packages/duckdb-wasm/src/bindings"

CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || sysctl -n hw.ncpu)

ADDITIONAL_FLAGS=
SUFFIX=
LINK_FLAGS=
case $MODE in
  "debug") ADDITIONAL_FLAGS="-DCMAKE_BUILD_TYPE=Debug -DWASM_FAST_LINKING=1" ;;
  "dev") ADDITIONAL_FLAGS="-DCMAKE_BUILD_TYPE=RelWithDebInfo -DWASM_FAST_LINKING=1" ;;
  "relsize") ADDITIONAL_FLAGS="-DCMAKE_BUILD_TYPE=Release -DWASM_MIN_SIZE=1" ;;
  "relperf") ADDITIONAL_FLAGS="-DCMAKE_BUILD_TYPE=Release" ;;
   *) ;;
esac
case $FEATURES in
  "mvp")
    ADDITIONAL_FLAGS="${ADDITIONAL_FLAGS} -DDUCKDB_CUSTOM_PLATFORM=wasm_mvp -DDUCKDB_EXPLICIT_PLATFORM=wasm_mvp"
    SUFFIX="-mvp"
    ;;
  "eh")
    ADDITIONAL_FLAGS="${ADDITIONAL_FLAGS} -DWITH_WASM_EXCEPTIONS=1 -DDUCKDB_CUSTOM_PLATFORM=wasm_eh -DDUCKDB_EXPLICIT_PLATFORM=wasm_eh"
    SUFFIX="-eh"
    ;;
  "coi")
    ADDITIONAL_FLAGS="${ADDITIONAL_FLAGS} -DWITH_WASM_EXCEPTIONS=1 -DWITH_WASM_THREADS=1 -DWITH_WASM_SIMD=1 -DWITH_WASM_BULK_MEMORY=1 -DDUCKDB_CUSTOM_PLATFORM=wasm_threads -DDUCKDB_EXPLICIT_PLATFORM=wasm_threads"
    SUFFIX="-coi"
    LINK_FLAGS="-pthread -sSHARED_MEMORY=1"
    ;;
   *) ;;
esac
echo "MODE=${MODE}"
echo "FEATURES=${FEATURES}"

BUILD_DIR="${PROJECT_ROOT}/build/${MODE}/${FEATURES}"
mkdir -p ${BUILD_DIR}

set -x

DUCKDB_WASM_VERSION_NAME=${DUCKDB_WASM_VERSION:-unknown}

emcmake cmake \
    -S${CPP_SOURCE_DIR} \
    -B${BUILD_DIR} \
    -DDUCKDB_WASM_VERSION=${DUCKDB_WASM_VERSION_NAME} \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DDUCKDB_LOCATION=${DUCKDB_LOCATION} \
    -DWASM_LINK_FLAGS_EXT="${LINK_FLAGS}" \
    -DDUCKDB_EXTENSION_CONFIGS=extension_config_wasm.cmake \
    ${ADDITIONAL_FLAGS}

emmake make \
    -C${BUILD_DIR} \
    -j${CORES} \
    duckdb_wasm

if [ "${USE_GENERATED_EXPORTED_LIST:-no}" == "yes" ]; then
make TARGET=${FEATURES} update_exported_list

emcmake cmake \
    -S${CPP_SOURCE_DIR} \
    -B${BUILD_DIR} \
    -DDUCKDB_WASM_VERSION=${DUCKDB_WASM_VERSION_NAME} \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DDUCKDB_LOCATION=${DUCKDB_LOCATION} \
    -DWASM_LINK_FLAGS_EXT="${LINK_FLAGS}" \
    -DDUCKDB_EXTENSION_CONFIGS=extension_config_wasm.cmake \
    -DUSE_GENERATED_EXPORTED_LIST=1 \
    ${ADDITIONAL_FLAGS}

emmake make \
    -C${BUILD_DIR} \
    -j${CORES} \
    duckdb_wasm
fi

js-beautify -v || npm install -g js-beautify
js-beautify ${BUILD_DIR}/duckdb_wasm.js > ${BUILD_DIR}/beauty.js
sed 's/case \"__table_base\"/case \"getTempRet0\": return getTempRet0;   case \"__table_base\"/g' ${BUILD_DIR}/beauty.js > ${BUILD_DIR}/beauty_sed.js
cp ${BUILD_DIR}/beauty_sed.js ${BUILD_DIR}/beauty.js
cp ${BUILD_DIR}/beauty.js ${BUILD_DIR}/duckdb_wasm.js
awk '{gsub(/get\(stubs, prop\) \{/,"get(stubs,prop) { if (prop.startsWith(\"invoke_\")) {return createDyncallWrapper(prop.substring(7));}"); print}' ${BUILD_DIR}/beauty.js > ${BUILD_DIR}/beauty2.js
awk '!(/var .*wasmExports\[/ || /var [_a-z0-9A-Z]+ = Module\[\"[_a-z0-9A-Z]+\"\] = [0-9]+;/) || /var _duckdb_web/ || /var _main/ || /var _calloc/ || /var _malloc/ || /var _free/ || /var stack/ || /var ___dl_seterr/ || /var __em/ || /var _em/ || /var _pthread/' ${BUILD_DIR}/beauty2.js > ${BUILD_DIR}/duckdb_wasm.js

cp ${BUILD_DIR}/duckdb_wasm.wasm ${DUCKDB_LIB_DIR}/duckdb${SUFFIX}.wasm
sed \
  -e "s/duckdb_wasm\.wasm/.\/duckdb${SUFFIX}.wasm/g" \
  ${BUILD_DIR}/duckdb_wasm.js > ${DUCKDB_LIB_DIR}/duckdb${SUFFIX}.js

if [ -f ${BUILD_DIR}/duckdb_wasm.worker.js ]; then
  sed \
    -e "s/duckdb_wasm\.wasm/.\/duckdb${SUFFIX}.wasm/g" \
    -e "s/duckdb_wasm\.js/.\/duckdb${SUFFIX}.js/g" \
    ${BUILD_DIR}/duckdb_wasm.worker.js > ${DUCKDB_LIB_DIR}/duckdb${SUFFIX}.pthread.js

  # Expose the module.
  # This will allow us to reuse the generated pthread handler and only overwrite the loading.
  # More info: duckdb-browser-async-coi.pthread.worker.ts
  printf "\nexport const onmessage = self.onmessage;\nexport function getModule() { return Module; }\nexport function setModule(m) { Module = m; }\n" \
    >> ${DUCKDB_LIB_DIR}/duckdb${SUFFIX}.pthread.js
fi
