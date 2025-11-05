#!/bin/bash

# 這個腳本用於下載和安裝最新的 geodata 和 i18n-iso-countries 資料夾
# 下載的檔案會被解壓縮到指定的目錄 (DOWNLOAD_DIR)
# 如果指定了 --install 參數，則會將檔案安裝到系統目錄 (僅限於 Docker 環境)

set -e

# --- 版本工具函數 ---
# 自動檢測 package.json 位置並取得版本字串，例如 1.140.1
get_pkg_version() {
  local pkg_path=""

  # 依優先順序檢查各個可能的路徑
  if [ -f "/usr/src/app/package.json" ]; then
    pkg_path="/usr/src/app/package.json"
  elif [ -f "/usr/src/app/server/package.json" ]; then
    pkg_path="/usr/src/app/server/package.json"
  elif [ -f "/app/immich/server/package.json" ]; then
    pkg_path="/app/immich/server/package.json"
  fi

  if [ -n "$pkg_path" ]; then
    echo "$pkg_path"
  else
    echo "錯誤：無法找到 Immich package.json 檔案" >&2
    echo "檢查的位置：" >&2
    echo "  - /usr/src/app/package.json" >&2
    echo "  - /usr/src/app/server/package.json" >&2
    echo "  - /app/immich/server/package.json" >&2
    echo "請確認此腳本在正確的 Immich 容器環境中執行。" >&2
    exit 1
  fi
}

# 傳回版本字串
get_pkg_version_value() {
  local path
  path=$(get_pkg_version)
  node -p "require('$path').version" 2>/dev/null
}

# 比較語義化版本：若 $1 < $2 則傳回 0 (true)，否則傳回 1 (false)
semver_lt() {
  local a="$1" b="$2"
  
  # 優先使用 npx semver（最標準的語意版本比較）
  if command -v npx >/dev/null 2>&1; then
    npx --yes semver "$a" -r "<$b" >/dev/null 2>&1
    return $?
  fi
  
  # 備援：使用 GNU sort -V 進行版本排序
  if command -v sort >/dev/null 2>&1 && sort --version-sort /dev/null >/dev/null 2>&1; then
    local sorted=$(printf "%s\n%s\n" "$a" "$b" | sort -V)
    local first_line=$(echo "$sorted" | head -n1)
    [ "$first_line" = "$a" ] && [ "$a" != "$b" ]
    return $?
  fi
  
  # 最後備援：安全的語意版本比較實現
  node -e "
    const [a, b] = process.argv.slice(1);
    const normalize = v => {
      const parts = v.split('.').map(Number);
      return [parts[0] || 0, parts[1] || 0, parts[2] || 0];
    };
    const [a0, a1, a2] = normalize(a);
    const [b0, b1, b2] = normalize(b);
    const lt = (a0 < b0) || (a0 === b0 && (a1 < b1 || (a1 === b1 && a2 < b2)));
    process.exit(lt ? 0 : 1);
  " "$a" "$b"
}
# --- 版本工具函數結束 ---

# 用戶可修改的配置
DOWNLOAD_DIR="./temp" # 普通模式下的下載目錄

# 預設值
RELEASE_TAG="latest"
INSTALL_MODE=false

# 解析參數
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --tag) RELEASE_TAG="$2"; shift; shift ;; # 讀取 --tag 後面的值
        --install) INSTALL_MODE=true; shift ;; # 識別 --install 參數
        *) echo "未知的參數: $1"; exit 1 ;;
    esac
done

# 構建下載連結和驗證 Tag (如果不是 latest)
if [ "$RELEASE_TAG" == "latest" ]; then
  DOWNLOAD_URL="https://github.com/RxChi1d/immich-geodata-zh-tw/releases/latest/download/release.tar.gz"
else
  # 驗證 Tag 是否存在
  echo "正在驗證 Tag: $RELEASE_TAG ..."
  TAG_CHECK_URL="https://api.github.com/repos/RxChi1d/immich-geodata-zh-tw/releases/tags/${RELEASE_TAG}"
  HTTP_STATUS=$(curl -o /dev/null -s -w "%{http_code}" "$TAG_CHECK_URL")

  if [ "$HTTP_STATUS" -eq 404 ]; then
    echo "錯誤：找不到指定的 Release Tag '$RELEASE_TAG'。"
    echo "請確認 Tag 名稱是否正確，或使用 'latest' 來下載最新版本。"
    exit 1
  elif [ "$HTTP_STATUS" -ne 200 ]; then
    # 處理其他可能的錯誤，例如網路問題或 API rate limit
    echo "錯誤：驗證 Tag '$RELEASE_TAG' 時發生問題 (HTTP Status: $HTTP_STATUS)。"
    exit 1
  fi
  echo "Tag '$RELEASE_TAG' 驗證成功。"
  DOWNLOAD_URL="https://github.com/RxChi1d/immich-geodata-zh-tw/releases/download/${RELEASE_TAG}/release.tar.gz"
fi

# 根據安裝模式決定下載目錄
if [ "$INSTALL_MODE" = true ]; then

  # 安裝模式：使用臨時目錄
  DOWNLOAD_DIR=$(mktemp -d -t immich_geodata_XXXXXX)
  echo "使用臨時目錄: $DOWNLOAD_DIR"

  # 註冊清理函數，在腳本結束時自動刪除臨時目錄
  cleanup() {
    if [ -d "$DOWNLOAD_DIR" ]; then
      echo "清理臨時目錄: $DOWNLOAD_DIR"
      rm -rf "$DOWNLOAD_DIR"
    fi
  }
  trap cleanup EXIT
else
  echo "使用指定目錄: $DOWNLOAD_DIR"
  if [ ! -d "$DOWNLOAD_DIR" ]; then
    echo "創建下載目錄: $DOWNLOAD_DIR"
    mkdir -p "$DOWNLOAD_DIR"
  else
    [ -d "$DOWNLOAD_DIR/geodata" ] && rm -rf "$DOWNLOAD_DIR/geodata"
    [ -d "$DOWNLOAD_DIR/i18n-iso-countries" ] && rm -rf "$DOWNLOAD_DIR/i18n-iso-countries"
  fi
fi

# 下載檔案
echo "開始下載 release.tar.gz 從 $DOWNLOAD_URL ..."
curl -L -o "$DOWNLOAD_DIR/release.tar.gz" "$DOWNLOAD_URL"


if [ $? -ne 0 ]; then
  echo "下載檔案失敗"
  exit 1
fi

# 解壓縮檔案
echo "開始解壓縮 release.tar.gz..."
tar --no-same-permissions -xvf "$DOWNLOAD_DIR/release.tar.gz" -C "$DOWNLOAD_DIR"

# 如果指定了 --install，執行安裝步驟
if [ "$INSTALL_MODE" = true ]; then
  echo "執行安裝步驟 (--install)..."

  PKG_PATH="$(get_pkg_version)"
  CURRENT_VERSION="$(get_pkg_version_value)"

  if [ -z "$CURRENT_VERSION" ]; then
    echo "警告：無法讀取 Immich 版本，將使用預設相容路徑。"
    CURRENT_VERSION="0.0.0"
  fi

  # 根據 package.json 路徑自動決定 i18n 模組目標
  case "$PKG_PATH" in
    "/usr/src/app/package.json")
      SYSTEM_I18N_PATH="/usr/src/app/node_modules/i18n-iso-countries"
      ;;
    "/usr/src/app/server/package.json")
      SYSTEM_I18N_PATH="/usr/src/app/server/node_modules/i18n-iso-countries"
      ;;
    "/app/immich/server/package.json")
      SYSTEM_I18N_PATH="/app/immich/server/node_modules/i18n-iso-countries"
      ;;
    *)
      echo "警告：未知的 Immich 結構，使用預設相容路徑 /usr/src/app/node_modules"
      SYSTEM_I18N_PATH="/usr/src/app/node_modules/i18n-iso-countries"
      ;;
  esac

  SYSTEM_GEODATA_PATH="/build/geodata"

  echo "偵測版本: $CURRENT_VERSION"
  echo "結構路徑: $PKG_PATH"
  echo "i18n 目標: $SYSTEM_I18N_PATH"

  echo "確保目標系統目錄存在..."
  mkdir -p /build
  mkdir -p "$(dirname "$SYSTEM_I18N_PATH")"

  # 備份現有系統檔案
  echo "備份現有系統檔案..."
  [ -d "$SYSTEM_GEODATA_PATH" ] && rm -rf "$SYSTEM_GEODATA_PATH.bak" && cp -a "$SYSTEM_GEODATA_PATH" "$SYSTEM_GEODATA_PATH.bak"
  [ -d "$SYSTEM_I18N_PATH" ] && rm -rf "$SYSTEM_I18N_PATH.bak" && cp -a "$SYSTEM_I18N_PATH" "$SYSTEM_I18N_PATH.bak"
  echo "備份完成。"

  echo "更新系統檔案..."
  if [ -d "$DOWNLOAD_DIR/geodata" ]; then
    echo "更新 geodata..."
    rm -rf "$SYSTEM_GEODATA_PATH"
    cp -a "$DOWNLOAD_DIR/geodata" "$SYSTEM_GEODATA_PATH"
    chown -R root:root "$SYSTEM_GEODATA_PATH"
  else
    echo "錯誤：geodata 資料夾不存在。"
  fi

  if [ -d "$DOWNLOAD_DIR/i18n-iso-countries" ]; then
    echo "更新 i18n-iso-countries..."
    mkdir -p "$SYSTEM_I18N_PATH"
    cp -a "$DOWNLOAD_DIR/i18n-iso-countries/." "$SYSTEM_I18N_PATH/"
    chown -R root:root "$SYSTEM_I18N_PATH"
  else
    echo "錯誤：i18n-iso-countries 資料夾不存在。"
  fi

  echo "系統檔案更新完成。"
  echo "安裝步驟完成 (Tag: $RELEASE_TAG)"
else
  echo "下載完成 (Tag: $RELEASE_TAG)"
fi
