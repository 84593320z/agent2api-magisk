#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · 插件二进制解释器修复
#
# 问题现场：面板里点"启动插件/切换代理内核"后，日志里出现
#    启动插件进程失败 … No such file or directory (os error 2)
#
# 为什么：插件/内核二进制是给桌面 Linux 编的，ELF 头里的 PT_INTERP 写着
#   /lib/ld-linux-aarch64.so.1
# 而 Android 的根分区只读、没有 /lib，这个文件永远不存在。内核 exec 时找不到
# 解释器直接 ENOENT（报的是"文件不存在"，但文件其实好好地在那儿，坑就在这）。
#
# 解法：把 PT_INTERP 那段字符串原地改成 /data/a2a/ld.so —— 软链指向我们自带
# 的那份真实 ld.so。原槽位 28 字节（"/lib/ld-linux-aarch64.so.1" 26 + 结尾
# NUL），新串 15 字节，其余补 NUL。phdr 不动、文件长度不动、偏移不动。
#
# 为什么不用 chroot / unshare -m：
#   chroot 要往模块目录里 bind-mount /dev /proc，异常退出留脏挂载；
#   unshare -m 在 KSU 上不一定有权限，同样有残留风险。改字符串是纯文件操作，
#   失败也只影响那一个二进制（而且只影响我们自己拉起来的进程）。
# ============================================================================

# 读 PT_INTERP 的位置：输出 "<p_offset> <p_filesz>"
# ELF64 布局：e_phoff@32(8B)、e_phentsize@54(2B)、e_phnum@56(2B)
# phdr：p_type@0(4B)、p_offset@8(8B)、p_filesz@32(8B)，phentsize 通常 56
interp_of() { # $1=ELF 文件
  [ -f "$1" ] || return 1
  elf_magic_ok "$1" || return 1
  [ "$(elf_arch "$1" 2>/dev/null)" = "aarch64" ] || return 1
  _phoff=$(od -An -tu8 -j32 -N8 "$1" 2>/dev/null | tr -d ' \t\r\n')
  _phes=$(od -An -tu2 -j54 -N2 "$1" 2>/dev/null | tr -d ' \t\r\n')
  _phnum=$(od -An -tu2 -j56 -N2 "$1" 2>/dev/null | tr -d ' \t\r\n')
  case "$_phoff$_phes$_phnum" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_phes" -ge 56 ] 2>/dev/null || return 1
  [ "$_phnum" -gt 0 ] 2>/dev/null || return 1
  [ "$_phnum" -lt 4096 ] 2>/dev/null || return 1
  _i=0
  while [ "$_i" -lt "$_phnum" ]; do
    _off=$((_phoff + _i * _phes))
    _type=$(od -An -tu4 -j"$_off" -N4 "$1" 2>/dev/null | tr -d ' \t\r\n')
    if [ "$_type" = "3" ]; then                     # 3 = PT_INTERP
      _poff=$(od -An -tu8 -j$((_off + 8)) -N8 "$1" 2>/dev/null | tr -d ' \t\r\n')
      _pfsz=$(od -An -tu8 -j$((_off + 32)) -N8 "$1" 2>/dev/null | tr -d ' \t\r\n')
      case "$_poff$_pfsz" in ''|*[!0-9]*) return 1 ;; esac
      [ "$_pfsz" -gt 0 ] 2>/dev/null || return 1
      [ "$_pfsz" -le 512 ] 2>/dev/null || return 1
      printf '%s %s' "$_poff" "$_pfsz"
      return 0
    fi
    _i=$((_i + 1))
  done
  return 1
}

# 读当前 interp 字符串（截到第一个 NUL）
interp_string() { # $1=ELF
  _r=$(interp_of "$1" 2>/dev/null) || return 1
  _poff=$(printf '%s' "$_r" | awk '{print $1}')
  _pfsz=$(printf '%s' "$_r" | awk '{print $2}')
  case "$_poff$_pfsz" in ''|*[!0-9]*) return 1 ;; esac
  dd if="$1" bs=1 skip="$_poff" count="$_pfsz" 2>/dev/null | tr -d '\000'
  return 0
}

# 把 interp 改成 $LDSO_LINK。
# 输出：ok（本来就好）/ fixed（改好了）/ static（无 interp，不用改）
#       other（interp 不是系统链接器，不动）/ toolong / verify-fail
# 返回 0 = 可用（ok / fixed / static），1 = 有问题
interp_fix() { # $1=ELF 文件
  _f="$1"
  _r=$(interp_of "$_f" 2>/dev/null) || { printf 'nointerp'; return 0; }
  _poff=$(printf '%s' "$_r" | awk '{print $1}')
  _pfsz=$(printf '%s' "$_r" | awk '{print $2}')
  case "$_poff$_pfsz" in ''|*[!0-9]*) printf 'nointerp'; return 0 ;; esac

  _cur=$(interp_string "$_f" 2>/dev/null)
  _want="$LDSO_LINK"

  [ "$_cur" = "$_want" ] && { printf 'ok'; return 0; }

  # 只处理"看起来是系统动态链接器"的。别的一律不碰 —— 宁可不动，也不要
  # 改坏别人的程序（尤其是 x86 交叉编译的插件，改了也跑不了）。
  # 只认"真的是 glibc 动态链接器"的解释器路径。
  # 旧白名单把 /apex/*、/system/lib* 也算进来，于是 bionic 的
  # /apex/com.android.runtime/bin/linker64、/system/bin/linker64 被改写成
  # 模块自带的 glibc ld.so —— 改完这个二进制再也起不来（ABI 完全不同）。
  case "$_cur" in
    *linker64|*linker) printf 'other:%s' "$_cur"; return 1 ;;
    /lib/ld-linux*.so*|/lib64/ld-linux*.so*|/usr/lib/ld-linux*.so*) ;;
    /system/lib64/ld-linux*.so*|/system/lib/ld-linux*.so*) ;;
    *) printf 'other:%s' "$_cur"; return 1 ;;
  esac

  # 新串必须能塞进原槽位（含结尾 NUL）
  [ $((${#_want} + 1)) -le "$_pfsz" ] || { printf 'toolong'; return 1; }

  # 副本上补丁、校验、再原子替换；断电最多留下 .interp.tmp 临时文件。
  _tmp="${_f}.interp.tmp"
  cp -f "$_f" "$_tmp" 2>/dev/null || { printf 'write-fail'; return 1; }
  dd if=/dev/zero of="$_tmp" bs=1 seek="$_poff" count="$_pfsz" conv=notrunc 2>/dev/null \
    || { rm -f "$_tmp"; printf 'write-fail'; return 1; }
  printf '%s' "$_want" | dd of="$_tmp" bs=1 seek="$_poff" conv=notrunc 2>/dev/null \
    || { rm -f "$_tmp"; printf 'write-fail'; return 1; }
  _after=$(interp_string "$_tmp" 2>/dev/null)
  [ "$_after" = "$_want" ] || { rm -f "$_tmp"; printf 'verify-fail'; return 1; }
  # 保留原权限位：有的插件是 0700/0750，无脑 755 等于替用户放宽了权限。
  # stat 取不到（老 toybox）才退回 755。
  _mode=$(stat -c %a "$_f" 2>/dev/null)
  _mode=$(printf %s "$_mode" | sed "s/[^0-7]//g")
  case "$_mode" in ''|*[!0-7]*) _mode=755 ;; esac
  chmod "$_mode" "$_tmp" 2>/dev/null || { rm -f "$_tmp"; printf 'write-fail'; return 1; }
  mv -f "$_tmp" "$_f" 2>/dev/null || { rm -f "$_tmp"; printf 'write-fail'; return 1; }
  # mv 后必须重新读取最终目标：临时文件校验通过不代表目标路径落盘正确。
  _after=$(interp_string "$_f" 2>/dev/null) || { printf 'verify-fail'; return 1; }
  [ "$_after" = "$_want" ] || { printf 'verify-fail'; return 1; }
  printf 'fixed'
  return 0
}

# 扫一个目录树，把所有"系统 interp"的二进制修掉。
# 跳过 .so（共享库没有 interp）；跳过非 ELF。
interp_fix_tree() { # $1=目录  $2=静默(1)
  [ -d "$1" ] || return 0
  # 本模块 POSIX sh 函数不用 local；递归时用专属变量，防止子层覆盖父层循环路径。
  _it_root="$1"
  _it_quiet="${2:-0}"
  for _it_file in "$_it_root"/*; do
    [ -e "$_it_file" ] || continue
    if [ -d "$_it_file" ]; then
      interp_fix_tree "$_it_file" "$_it_quiet"
      continue
    fi
    elf_magic_ok "$_it_file" || continue
    case "$_it_file" in *.so|*.so.*) continue ;; esac
    _it_res=$(interp_fix "$_it_file" 2>/dev/null)
    case "$_it_res" in
      fixed)
        log_to "$SUPLOG" "interp 已改写 -> $LDSO_LINK ：$_it_file"
        [ "$_it_quiet" = "1" ] || say "  已修复解释器：${_it_file#/data/adb/agent2api/}"
        ;;
      verify-fail|toolong|write-fail)
        log_to "$SUPLOG" "interp 改写失败（$_it_res）：$_it_file"
        [ "$_it_quiet" = "1" ] || say "  ! 解释器改写失败（$_it_res）：${_it_file#/data/adb/agent2api/}"
        ;;
    esac
  done
  return 0
}

# 面板插件目录：$DATADIR/plugins/<pack>/bin/*
# 上游插件装在 AGENT2API_PROXY_HOME(= $DATADIR) 下面；不同版本目录布局略有
# 差异，所以两处都扫，扫不到就算了（不影响主服务）。
plugin_interp_fix() {
  # Dynamic server uses synchronous spawn adaptation. Keep signed packages intact.
  if [ -r "$MODDIR/libexec/plugin-spawn.so" ] && command -v payload_is_static >/dev/null 2>&1 && ! payload_is_static; then
    return 0
  fi
  [ "$(cfg_get plugin_interp 1)" = "1" ] || return 0
  [ -x "$LDSO_LINK" ] || live_link_refresh
  if [ ! -x "$LDSO_LINK" ]; then
    log_to "$SUPLOG" "跳过插件解释器修复：$LDSO_LINK 不可用"
    return 0
  fi
  for _p in "$DATADIR" "$HOMEDIR"; do
    [ -d "$_p" ] || continue
    for _d in "$_p"/plugins "$_p"/providers "$_p"/kernels; do
      [ -d "$_d" ] || continue
      [ -d "$_d/bin" ] && interp_fix_tree "$_d/bin" 0
      # 原来用三层 glob 展开（峰值上千次 stat，插件多的机器明显卡）；
      # find -maxdepth 3 一次遍历，命中率一样。
      find "$_d" -mindepth 1 -maxdepth 3 -type d -name bin 2>/dev/null | while IFS= read -r _sub; do
        interp_fix_tree "$_sub" 0
      done
    done
    # 3.5+ 的 Bun 不在 bin/ 中，而是 runtimes/bun/<版本>/<资产名>/bun。
    # 动态 server 已在函数入口走 spawn 桥；这里只服务静态/桥缺失的回退路径。
    [ ! -d "$_p/runtimes" ] || interp_fix_tree "$_p/runtimes" 0
  done
  return 0
}