#!/bin/sh
# ============================================================================
# libexec/mkdir.sh 回归测试（纯 POSIX sh，不需要真机）
#
# 模拟 KernelSU 安装器/运行期的 standalone busybox：那个环境里
# `mkdir -p <绝对路径>` 必定失败（"can't create directory '/'"），而
# `mkdir <绝对路径>`（不带 -p）正常。这里用一个假 mkdir 复刻这个缺陷，
# 验证兼容层仍然能把目录建出来、并且失败时留下真实错误。
#
# 注意：包装函数里用的是 `command mkdir`，所以假 mkdir 必须放在 PATH 里，
# 而不是定义成 shell 函数。
# ============================================================================

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../module"
WORK="$HERE/out/mkdir"
FAIL=0

rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/tree" || exit 1

# 定位真正的 mkdir：必须是一个真实路径，否则假 mkdir 会 exec 自己。
REAL_MKDIR=
for _c in /usr/bin/mkdir /bin/mkdir; do
  if [ -x "$_c" ]; then
    REAL_MKDIR=$_c
    break
  fi
done
if [ -z "$REAL_MKDIR" ]; then
  echo "  SKIP 找不到真正的 mkdir，跳过"
  rm -rf "$WORK"
  exit 0
fi

# 假 mkdir：复刻 standalone 缺陷 —— 带 -p 且路径是绝对路径时失败。
cat > "$WORK/bin/mkdir" <<EOF
#!/bin/sh
_hasp=
_abs=
for _a in "\$@"; do
  case \$_a in
    -p|--parents) _hasp=1 ;;
    /*) _abs=\$_a ;;
  esac
done
if [ -n "\$_hasp" ] && [ -n "\$_abs" ]; then
  echo "mkdir: can't create directory '/': Invalid argument" >&2
  exit 1
fi
exec "$REAL_MKDIR" "\$@"
EOF
chmod +x "$WORK/bin/mkdir" || exit 1

# 先确认假 mkdir 真的能复现缺陷。某些环境（例如把 mkdir 做成内建命令的
# 工具链）里 `command mkdir` 不走 PATH，假 mkdir 不会生效；那种情况下下面的
# 用例仍然验证包装函数的行为，只是没有覆盖"逐级兜底"这条分支。
if PATH="$WORK/bin:$PATH" command mkdir -p "$WORK/tree/probe" 2>/dev/null; then
  echo "  SKIP 当前 shell 的 mkdir 不受 PATH 影响，未覆盖逐级兜底分支"
fi

PATH="$WORK/bin:$PATH"
. "$SRC/libexec/mkdir.sh" || { echo "  FAIL 无法加载 libexec/mkdir.sh"; rm -rf "$WORK"; exit 1; }
[ -n "${A2A_MKDIR_SH:-}" ] || { echo "  FAIL 未设置 A2A_MKDIR_SH 保护标记"; FAIL=1; }

check() {
  _label=$1
  shift
  if "$@"; then
    echo "  ok   $_label"
  else
    echo "  FAIL $_label"
    FAIL=1
  fi
}

mkdir -p "$WORK/tree/a/b/c" 2>/dev/null
check "绝对路径多级目录" [ -d "$WORK/tree/a/b/c" ]

mkdir -p "$WORK/tree/x" "$WORK/tree/y/z" 2>/dev/null
check "多个目录参数" [ -d "$WORK/tree/y/z" ]

mkdir -p "$WORK/tree/a" 2>/dev/null
check "已存在的目录返回 0" [ $? -eq 0 ]

mkdir -p "$WORK/tree/sp ace/d" 2>/dev/null
check "路径含空格" [ -d "$WORK/tree/sp ace/d" ]

( cd "$WORK/tree" && mkdir -p rel/1/2 ) 2>/dev/null
check "相对路径" [ -d "$WORK/tree/rel/1/2" ]

# 真正的失败必须冒出来，不能被兜底吞掉。
: > "$WORK/tree/afile"
mkdir -p "$WORK/tree/afile/under" 2>/dev/null
check "父路径是文件时返回非 0" [ $? -ne 0 ]
check "失败时留下真实错误" [ -n "${A2A_MKDIR_ERR:-}" ]

mkdir -p -m 700 "$WORK/tree/mode" 2>/dev/null
check "不支持的选项返回 2" [ $? -eq 2 ]

# 不带 -p 的 mkdir 必须保持"已存在即失败"的原语义：dns.sh 用它做互斥锁。
mkdir "$WORK/tree/lock" 2>/dev/null
check "不带 -p 建新目录成功" [ -d "$WORK/tree/lock" ]
mkdir "$WORK/tree/lock" 2>/dev/null
check "不带 -p 重复创建返回非 0（锁语义）" [ $? -ne 0 ]

rm -rf "$WORK"
if [ "$FAIL" -eq 0 ]; then
  echo "=== mkdir 兼容层测试通过 ==="
  exit 0
fi
echo "=== mkdir 兼容层测试失败 ==="
exit 1
