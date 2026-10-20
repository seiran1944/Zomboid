#!/bin/sh

# ==============================================================================
# ANSI COLOR CODES
# ==============================================================================
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

# ==============================================================================
# CONFIG FILE LOADER
# ==============================================================================
CONFIG_FILE="./mod_merger.conf"

if [ -f "$CONFIG_FILE" ]; then
    echo "偵測到參數設定檔 [ $CONFIG_FILE ]，正在載入自訂設定..."
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#*|""|[[:space:]]*) continue ;;
        esac
        key=$(echo "$line" | cut -d'=' -f1 | tr -d ' ')
        val=$(echo "$line" | cut -d'=' -f2- | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//")
        if [ -n "$key" ]; then
            eval "FILE_$key=\"\$val\""
        fi
    done < "$CONFIG_FILE"
fi

# ==============================================================================
# AUTO-DETECT DEFAULT PATHS BASED ON OS
# ==============================================================================
if echo "$(uname -s)" | grep -qiE "mingw|msys|cygwin|wsl"; then
    USER_HOME="/c/Users/$USER"
    [ -d "$USER_HOME" ] || USER_HOME="$HOME"
    DEFAULT_WORKSHOP_DIR="$USER_HOME/AppData/Local/Steam/steamapps/workshop/content/108600"
    [ -d "$DEFAULT_WORKSHOP_DIR" ] || DEFAULT_WORKSHOP_DIR="/c/Program Files (x86)/Steam/steamapps/workshop/content/108600"
    DEFAULT_DEFAULT_TXT="$USER_HOME/Zomboid/mods/default.txt"
    DEFAULT_MODS_DIR="$USER_HOME/Zomboid/mods"
    DEFAULT_WORKSHOP_OUT_DIR="$USER_HOME/Zomboid/Workshop/MyCustomModPack"
else
    DEFAULT_WORKSHOP_DIR="$HOME/.steam/steam/steamapps/workshop/content/108600"
    DEFAULT_DEFAULT_TXT="$HOME/Zomboid/mods/default.txt"
    DEFAULT_MODS_DIR="$HOME/Zomboid/mods"
    DEFAULT_WORKSHOP_OUT_DIR="$HOME/Zomboid/Workshop/MyCustomModPack"
fi

DEFAULT_TEMP_DIR="."
DEFAULT_PACK_NAME="My Mods Combo"
DEFAULT_PACK_ID="MyModsCombo"

# ==============================================================================
# USER INPUT COLLECTOR & MODE CHOICE
# ==============================================================================
echo "=== Project Zomboid B42 Mod Packager (Pure ASCII Safe Edition) ==="
echo "修復更新：已移除 echo 中可能引發語法錯誤的半形刮號"
echo "客製化更新：解法 A+ 本地子模組自動追加 _local 後綴並清除 Steam 痕跡"
echo ""

sanitize_path() {
    echo "$1" | sed 's/\\/\//g' | sed 's/^\([A-Za-z]\):/\/\1/'
}

# 模式選擇
echo "請選擇打包模式："
echo "1) 解法 A+ [本地平鋪包 與 一鍵連動遙控器，免上傳，直接放 Zomboid/mods]"
echo "2) 解法 B  [工作坊上傳包，建立 Contents/mods 結構，專門用來 Private 上傳]"
printf "請輸入選項 [1 或 2, 預設 1]: "
read -r pack_mode
pack_mode="${pack_mode:-1}"

if [ -n "$FILE_TEMP_DIR" ]; then
    TEMP_DIR=$(sanitize_path "$FILE_TEMP_DIR")
else
    printf "Enter Temp Directory Path (Leave blank for current dir) [%s]: " "$DEFAULT_TEMP_DIR"
    read -r input_temp
    TEMP_DIR=$(sanitize_path "${input_temp:-$DEFAULT_TEMP_DIR}")
fi
mkdir -p "$TEMP_DIR"

if [ -n "$FILE_WORKSHOP_DIR" ]; then
    WORKSHOP_DIR=$(sanitize_path "$FILE_WORKSHOP_DIR")
else
    printf "Enter Steam Workshop Path [%s]: " "$DEFAULT_WORKSHOP_DIR"
    read -r input_workshop
    WORKSHOP_DIR=$(sanitize_path "${input_workshop:-$DEFAULT_WORKSHOP_DIR}")
fi

if [ -n "$FILE_DEFAULT_TXT" ]; then
    DEFAULT_TXT=$(sanitize_path "$FILE_DEFAULT_TXT")
else
    printf "Enter Zomboid default.txt Path [%s]: " "$DEFAULT_DEFAULT_TXT"
    read -r input_txt
    DEFAULT_TXT=$(sanitize_path "${input_txt:-$DEFAULT_DEFAULT_TXT}")
fi

if [ "$pack_mode" = "1" ]; then
    if [ -n "$FILE_MODS_DIR" ]; then
        OUTPUT_DIR=$(sanitize_path "$FILE_MODS_DIR")
    else
        OUTPUT_DIR="$DEFAULT_MODS_DIR"
    fi
    echo "模式：解法 A+ -> 輸出至本地端目錄: $OUTPUT_DIR"
else
    if [ -n "$FILE_WORKSHOP_OUT_DIR" ]; then
        OUTPUT_DIR=$(sanitize_path "$FILE_WORKSHOP_OUT_DIR")
    else
        OUTPUT_DIR="$DEFAULT_WORKSHOP_OUT_DIR"
    fi
    echo "模式：解法 B  -> 輸出至工作坊專案目錄: $OUTPUT_DIR"
fi

printf "請輸入你的合集包名稱（🚨請一律輸入純英文，避免亂碼）[%s]: " "$DEFAULT_PACK_NAME"
read -r pack_name
pack_name="${pack_name:-$DEFAULT_PACK_NAME}"

printf "請輸入你的合集包唯一 ID [%s]: " "$DEFAULT_PACK_ID"
read -r pack_id
pack_id="${pack_id:-$DEFAULT_PACK_ID}"

# 強制洗滌包名，移除任何非 ASCII 字元與奇怪符號
safe_pack_name=$(echo "$pack_name" | sed 's/[^a-zA-Z0-9 _-]//g')
safe_pack_id=$(echo "$pack_id" | sed 's/[^a-zA-Z0-9_-]//g')

# ==============================================================================
# VALIDATION
# ==============================================================================
if [ ! -d "$WORKSHOP_DIR" ]; then
    echo "ERROR: Workshop directory does not exist: $WORKSHOP_DIR" >&2
    exit 1
fi
if [ ! -f "$DEFAULT_TXT" ]; then
    echo "ERROR: default.txt file not found: $DEFAULT_TXT" >&2
    exit 1
fi

ACTIVE_MODS_LIST=$(sed -n '/mods/,/\}/p' "$DEFAULT_TXT" | grep 'mod *=' | sed 's/.*mod *= *//' | tr -d '\r ,' )
if [ -z "$ACTIVE_MODS_LIST" ]; then
    echo "ERROR: No active mod IDs found inside default.txt." >&2
    exit 1
fi

# ==============================================================================
# PHASE 1: SCANNING & TRUE ROOT RESOLVING
# ==============================================================================
echo "正在深度掃描工作坊模組來源並解析相依模組 (Require)..."

TMP_RAW_SCANNED="$TEMP_DIR/.pz_raw_scanned.$$"
TMP_MATCHED_ROOTS="$TEMP_DIR/.pz_matched_roots.$$"
TMP_FOUND_IDS="$TEMP_DIR/.pz_found_ids.$$"
TMP_TARGET_IDS="$TEMP_DIR/.pz_target_ids.$$"
touch "$TMP_RAW_SCANNED" "$TMP_MATCHED_ROOTS" "$TMP_FOUND_IDS" "$TMP_TARGET_IDS"

# 先將預設啟用的模組放入目標清單
echo "$ACTIVE_MODS_LIST" > "$TMP_TARGET_IDS"

# 建立所有工作坊 mod.info 的快取，避免重複硬碟 IO 掃描
find "$WORKSHOP_DIR" -type f -name "mod.info" | while read -r info_path; do
    real_id=$(grep '^id=' "$info_path" | head -n 1 | cut -d'=' -f2 | tr -d '\r ')
    [ -z "$real_id" ] && continue

    current_dir=$(dirname "$info_path")
    base_name=$(basename "$current_dir")
    if echo "$base_name" | grep -qE '^42([.][0-9]+)?$'; then
        true_mod_root=$(dirname "$current_dir")
    else
        true_mod_root="$current_dir"
    fi
    
    # 紀錄原始對應與對應的 require 關係
    req_line=$(grep '^require=' "$info_path" | head -n 1 | cut -d'=' -f2- | tr -d '\r ')
    echo "$real_id|$true_mod_root|$req_line" >> "$TMP_RAW_SCANNED"
done

# 【優化】深度遞迴掃描相依性，直到不再長出新模組為止
HAS_NEW=1
while [ "$HAS_NEW" -eq 1 ]; do
    HAS_NEW=0
    CURRENT_TARGETS=$(cat "$TMP_TARGET_IDS")
    
    echo "$CURRENT_TARGETS" | while read -r target_id; do
        [ -z "$target_id" ] && continue
        # 找出該 target_id 的所有 require 項目
        grep "^$target_id|" "$TMP_RAW_SCANNED" | cut -d'|' -f3 | while read -r req_line; do
            [ -z "$req_line" ] && continue
            echo "$req_line" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | while read -r single_req; do
                [ -z "$single_req" ] && continue
                if ! grep -qx "$single_req" "$TMP_TARGET_IDS"; then
                    echo "$single_req" >> "$TMP_TARGET_IDS"
                    # 使用全域方式標記有新模組，打破迴圈以便下一輪繼續檢查
                    touch "$TEMP_DIR/.pz_has_new.$$"
                fi
            done
        done
    done
    if [ -f "$TEMP_DIR/.pz_has_new.$$" ]; then
        HAS_NEW=1
        rm -f "$TEMP_DIR/.pz_has_new.$$"
    fi
done

# 第二階段：根據最終的目標清單（包含原生與 require 的模組）進行 Root 匹配
cat "$TMP_TARGET_IDS" | while read -r target_id; do
    [ -z "$target_id" ] && continue
    all_roots=$(grep "^$target_id|" "$TMP_RAW_SCANNED" | cut -d'|' -f2 | sort -u)
    [ -z "$all_roots" ] && continue

    chosen_root=$(echo "$all_roots" | head -n 1)
    if [ -n "$chosen_root" ]; then
        if ! grep -qxF "$chosen_root" "$TMP_MATCHED_ROOTS"; then
            # 判斷是否為原本 default.txt 就有的模組，如果不是，就是相依 (require) 模組
            if echo "$ACTIVE_MODS_LIST" | grep -qx "$target_id"; then
                echo "$target_id|$chosen_root|DIRECT" >> "$TMP_MATCHED_ROOTS"
				printf "${COLOR_BLUE}[DIRECT][REQUIRE] Mod ID: %s ${COLOR_RESET}\n" "$target_id"
            else
                echo "$target_id|$chosen_root|REQUIRE" >> "$TMP_MATCHED_ROOTS"
				printf "${COLOR_BLUE}[REQUIRE] Mod ID: %s ${COLOR_RESET}\n" "$target_id"
            fi
            echo "$target_id" >> "$TMP_FOUND_IDS"
        fi
    fi
done

# ==============================================================================
# PHASE 2: PREVIEW
# ==============================================================================
echo ""
echo "==================== FINAL MOD COPY PREVIEW ===================="
if [ -s "$TMP_MATCHED_ROOTS" ]; then
    while IFS='|' read -r mid mroot mtype; do
        if [ "$mtype" = "REQUIRE" ]; then
            printf "${COLOR_BLUE}[REQUIRE] Mod ID: %s -> %s${COLOR_RESET}\n" "$mid" "$mroot"
        else
            printf "${COLOR_GREEN}[FOUND]   Mod ID: %s -> %s${COLOR_RESET}\n" "$mid" "$mroot"
        fi
    done < "$TMP_MATCHED_ROOTS"
else
    echo "No matching workshop folders found."
fi
echo "=========================================================="
echo ""

printf "確認要開始搬移與封裝模組嗎？ [y/N]: "
read -r user_confirm
case "$user_confirm" in [yY][eE][sS]|[yY]) ;; *) echo "取消操作。"; rm -f "$TMP_RAW_SCANNED" "$TMP_MATCHED_ROOTS" "$TMP_FOUND_IDS" "$TMP_TARGET_IDS"; exit 0;; esac

# ==============================================================================
# PHASE 3: EXECUTION (A+ vs B) - Build 42 完全符合版
# ==============================================================================
if [ "$pack_mode" = "1" ]; then
    TARGET_CONTAINER_DIR="$OUTPUT_DIR"
    mkdir -p "$TARGET_CONTAINER_DIR"
    
    echo "正在執行解法 A+ 本地平鋪包模式（符合 B42 規範）..."
    REQUIRE_STR=""
    
    while IFS='|' read -r mid mroot mtype; do
        # 決定本地端資料夾名稱，為了區分，資料夾名稱也加上 _local
        clean_folder_name=$(echo "${mid}_local" | tr -d " '[]()")
        echo "--> 正在完整打包子模組 (加字尾): $clean_folder_name"
        
        # 本地平鋪子模組：建立本地版資料夾並複製檔案
        mkdir -p "$TARGET_CONTAINER_DIR/$clean_folder_name"
        cp -Rp "$mroot/." "$TARGET_CONTAINER_DIR/$clean_folder_name/"
        
        # 強制確保子模組根目錄存在一份有效的 mod.info
        if [ ! -f "$TARGET_CONTAINER_DIR/$clean_folder_name/mod.info" ]; then
            if [ -f "$TARGET_CONTAINER_DIR/$clean_folder_name/42/mod.info" ]; then
                cp "$TARGET_CONTAINER_DIR/$clean_folder_name/42/mod.info" "$TARGET_CONTAINER_DIR/$clean_folder_name/mod.info"
            elif [ -f "$TARGET_CONTAINER_DIR/$clean_folder_name/42.0/mod.info" ]; then
                cp "$TARGET_CONTAINER_DIR/$clean_folder_name/42.0/mod.info" "$TARGET_CONTAINER_DIR/$clean_folder_name/mod.info"
            fi
        fi
        
        # 【新增自動修改 ID 邏輯】
        # 尋找本地複製版中所有的 mod.info 並將 id 加上 _local 後綴，同時移除 workshopID 和 url
        find "$TARGET_CONTAINER_DIR/$clean_folder_name" -type f -name "mod.info" | while read -r sub_info; do
            # 1. 修改 id= 行（加上 ^ 與 = 限制，且避免重複附加 _local）
            sed -i -E '/^id=/ { /_local$/! s/^id=(.*)/id=\1_local/ }' "$sub_info"
            
            # 2. 移除 workshopID 與 url 的連動
            sed -i '/^workshopID=/d' "$sub_info"
            sed -i '/^url=/d' "$sub_info"
            
            # 3. 【完美修復】精確解析 require= 行，利用 awk 或更安全的 sed 規則，只針對尚未有 _local 的 ID 加上字尾
            # 這邊改用先抓出 require 內容，再透過轉換，徹底根除 SpnOpenClothBase 被攔腰斬斷的問題
            if grep -q '^require=' "$sub_info"; then
                req_content=$(grep '^require=' "$sub_info" | cut -d'=' -f2- | tr -d '\r\n')
                new_req=""
                IFS=','
                for item in $req_content; do
                    # 清除前後空白
                    clean_item=$(echo "$item" | sed 's/^ *//;s/ *$//')
                    [ -z "$clean_item" ] && continue
                    
                    # 如果該相依模組 ID 結尾還沒有 _local，就幫它加上
                    if ! echo "$clean_item" | grep -q '_local$'; then
                        clean_item="${clean_item}_local"
                    fi
                    
                    if [ -z "$new_req" ]; then
                        new_req="$clean_item"
                    else
                        new_req="${new_req}, ${clean_item}"
                    fi
                done
                unset IFS
                
                # 刪除舊的 require 行，並在 id= 後面補上全新的 require=
                sed -i '/^require=/d' "$sub_info"
                # 在 id= 的下一行精確插入修改後的 require= 行
                sed -i "/^id=/a require=$new_req" "$sub_info"
            fi
        done
		
        # 【修正 2】移除舊反斜線錯誤，完美賦值變數，代入加了 _local 的新 ID
        new_local_id="\\${mid}_local"
        if [ -z "$REQUIRE_STR" ]; then
            REQUIRE_STR="$new_local_id"
        else
            REQUIRE_STR="${REQUIRE_STR},${new_local_id}"
        fi
    done < "$TMP_MATCHED_ROOTS"

    # 【修正 1】建立一鍵連動遙控器（建立正確的 B42 本地方流路徑）
    CONTROLLER_ID="00_${safe_pack_id}_ctrl"
    CONTROLLER_DIR="$TARGET_CONTAINER_DIR/00_${safe_pack_id}_Controller"

    # 建立 B42 本地端專用的 42/contents/mods/ 階層
    B42_LOCAL_MOD_DIR="$CONTROLLER_DIR/42/contents/mods/$CONTROLLER_ID"
    mkdir -p "$B42_LOCAL_MOD_DIR"
    mkdir -p "$CONTROLLER_DIR/common" # 留作備用

    # 【修正 3】移除 ===，使用標準單一等號格式
    cat << EOF > "$B42_LOCAL_MOD_DIR/mod.info"
name=$safe_pack_name
id=$CONTROLLER_ID
description=Enable this mod to automatically enable all combined local submods.
require=$REQUIRE_STR
poster=poster.png
EOF

    # 同步複製一份到控制器根目錄，確保相容性
    cp "$B42_LOCAL_MOD_DIR/mod.info" "$CONTROLLER_DIR/mod.info"
    touch "$B42_LOCAL_MOD_DIR/poster.png"
    touch "$CONTROLLER_DIR/poster.png"
    echo ""
    echo "✨ 成功！解法 A+ 打包完成！"
    echo "檔案已平鋪儲存於: $TARGET_CONTAINER_DIR"
    echo "👉 現在請直接重啟遊戲 -> 點 Mods -> 勾選「$safe_pack_name」即可享受一鍵全亮綠燈！"
else
    # 【修正 4】建立符合 B42 的工作坊上傳結構 (Contents/42/contents/mods/)
    TARGET_CONTAINER_DIR="$OUTPUT_DIR/Contents/42/contents/mods"
    mkdir -p "$TARGET_CONTAINER_DIR"
    touch "$OUTPUT_DIR/preview.png"
    echo "正在執行解法 B 工作坊上傳包模式（符合 B42 工作坊規範）..."
    while IFS='|' read -r mid mroot mtype; do
        clean_folder_name=$(echo "$mid" | tr -d " '")
        echo "--> 正在打包至工作坊 B42 子目錄: $clean_folder_name"
        mkdir -p "$TARGET_CONTAINER_DIR/$clean_folder_name"
        cp -Rp "$mroot/." "$TARGET_CONTAINER_DIR/$clean_folder_name/"
        if [ ! -d "$TARGET_CONTAINER_DIR/$clean_folder_name/common" ]; then
            mkdir -p "$TARGET_CONTAINER_DIR/$clean_folder_name/common"
        fi
    done < "$TMP_MATCHED_ROOTS"
    echo ""
    echo "✨ 成功！解法 B 打包完成！"
    echo "工作坊專案已儲存於: $OUTPUT_DIR"
    echo "👉 現在請打開遊戲 -> 點 Mods -> 進入 Workshop Item Editor 即可一鍵 Private 上傳至 Steam！"
fi

rm -f "$TMP_RAW_SCANNED" "$TMP_MATCHED_ROOTS" "$TMP_FOUND_IDS" "$TMP_TARGET_IDS"
