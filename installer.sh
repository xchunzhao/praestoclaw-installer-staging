#!/usr/bin/env bash
# qa-record 全自动一键安装（macOS / Linux）
# 用法：
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/xchunzhao/praestoclaw-installer-staging/qa-record/installer.sh)"

set -e

# ========== 仓库位置（同一分支放 installer 和 tgz） ==========
RAW_BASE="https://raw.githubusercontent.com/xchunzhao/praestoclaw-installer-staging/qa-record"
TGZ_NAME="qa-record.tgz"

# ========== 可选环境 ==========
ENV_NAMES=("staging" "production" "dev")
ENV_URLS=(
    "https://staging.societas.microsoft.com"
    "https://societas.microsoft.com"
    "https://dev.societas.microsoft.com"
)
ENV_LOGIN_PATH="/login"
# ==============================

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; GRAY='\033[0;90m'; NC='\033[0m'
info()  { echo -e "  ${GRAY}$1${NC}"; }
ok()    { echo -e "  ${GREEN}✓ $1${NC}"; }
warn()  { echo -e "  ${YELLOW}! $1${NC}"; }
fail()  { echo -e "  ${RED}✗ $1${NC}"; }
step()  { echo; echo -e "${CYAN}[$1] $2${NC}"; }

echo
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}  qa-record 全自动安装${NC}"
echo -e "${CYAN}==========================================${NC}"

# ---------- 1. 确保 Node.js >= 18 ----------
step 1 "检查 / 安装 Node.js"
need_install_node=1
if command -v node >/dev/null 2>&1; then
    v=$(node -v)
    major=$(echo "$v" | sed -E 's/v([0-9]+)\..*/\1/')
    if [ "$major" -ge 18 ]; then
        need_install_node=0
        ok "已装 Node.js $v"
    else
        warn "Node.js $v 太旧，将升级"
    fi
fi

if [ "$need_install_node" -eq 1 ]; then
    os=$(uname -s)
    if [ "$os" = "Darwin" ]; then
        if command -v brew >/dev/null 2>&1; then
            info "用 Homebrew 安装 Node.js..."
            brew install node
        else
            info "未装 Homebrew，正在安装..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            # 加进当前 shell PATH
            if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
            if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
            brew install node
        fi
    elif [ "$os" = "Linux" ]; then
        if command -v apt-get >/dev/null 2>&1; then
            info "用 apt 安装 Node.js LTS..."
            curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
            sudo apt-get install -y nodejs
        elif command -v yum >/dev/null 2>&1; then
            curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
            sudo yum install -y nodejs
        else
            fail "不支持的 Linux 发行版，请手动装 Node.js 18+"
            exit 1
        fi
    else
        fail "不支持的系统: $os"
        exit 1
    fi
    ok "已安装 Node.js $(node -v)"
fi

# ---------- 2. 下载 tgz ----------
step 2 "下载安装包"
tgz_url="$RAW_BASE/$TGZ_NAME"
tmp_tgz=$(mktemp -t qa-record.XXXXXX).tgz
if ! curl -fsSL -o "$tmp_tgz" "$tgz_url"; then
    fail "下载失败: $tgz_url"
    exit 1
fi
ok "已下载 $TGZ_NAME"

# ---------- 3. 解压（自带依赖，无需 npm install） ----------
step 3 "解压安装"
INSTALL_DIR="$HOME/.qa-record"
mkdir -p "$INSTALL_DIR"
# 只清程序代码，保留 tests/ / auth.json / qa.config.js 等用户数据
rm -rf "$INSTALL_DIR/dist" "$INSTALL_DIR/bin" "$INSTALL_DIR/node_modules" "$INSTALL_DIR/package.json"
tar -xzf "$tmp_tgz" -C "$INSTALL_DIR"
rm -f "$tmp_tgz"

if [ ! -d "$INSTALL_DIR/node_modules/playwright-core" ]; then
    fail "解压后 playwright-core 缺失"
    exit 1
fi
ok "已安装（含依赖，无需 npm install）"

# ---------- 4. 注册命令 ----------
step 4 "注册 qa-record 命令"
BIN_DIR="$HOME/.qa-record-bin"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/qa-record" <<EOF
#!/usr/bin/env bash
exec node "$INSTALL_DIR/bin/qa-record.js" "\$@"
EOF
chmod +x "$BIN_DIR/qa-record"

# 加进 PATH（幂等）
add_to_rc() {
    local rc="$1"
    if [ -f "$rc" ] && ! grep -q ".qa-record-bin" "$rc"; then
        echo '' >> "$rc"
        echo '# qa-record' >> "$rc"
        echo "export PATH=\"\$HOME/.qa-record-bin:\$PATH\"" >> "$rc"
        info "已写入 $rc"
    fi
}
add_to_rc "$HOME/.zshrc"
add_to_rc "$HOME/.bashrc"
add_to_rc "$HOME/.bash_profile"
export PATH="$BIN_DIR:$PATH"
ok "已加入 PATH"

# ---------- 5. 选择环境并写入全局 config ----------
config_path="$INSTALL_DIR/qa.config.js"
if [ -f "$config_path" ]; then
    step 5 "已有配置，跳过环境选择"
    ok "沿用现有配置: $config_path"
    info "如需切换环境：改这个文件里的 baseURL"
else
    step 5 "选择要测试的环境"
    echo
    for i in "${!ENV_NAMES[@]}"; do
        printf "  %d) %-12s %s\n" $((i + 1)) "${ENV_NAMES[$i]}" "${ENV_URLS[$i]}"
    done
    echo

    selected_idx=0
    if [ -e /dev/tty ]; then
        read -p "请输入序号 [1]: " choice </dev/tty || choice=""
        [ -z "$choice" ] && choice=1
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ENV_NAMES[@]}" ]; then
            selected_idx=$((choice - 1))
        else
            warn "输入无效，默认使用 1"
        fi
    else
        info "无法读取输入，默认使用 1 - ${ENV_NAMES[0]}"
    fi

    sel_name="${ENV_NAMES[$selected_idx]}"
    sel_url="${ENV_URLS[$selected_idx]}"
    cat > "$config_path" <<EOF
// qa-record 全局配置。install 时选的环境，可随时改。
module.exports = {
  baseURL: '$sel_url',
  loginCheck: { urlIncludes: '$ENV_LOGIN_PATH' },
};
EOF
    ok "已配置环境: $sel_name ($sel_url)"
    info "如需切换：改 $config_path"
fi

echo
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  ✅ 安装完成${NC}"
echo -e "${GREEN}==========================================${NC}"
echo
echo -e "${CYAN}使用（新开一个终端窗口）：${NC}"
echo "  qa-record <test-case-id>"
echo
