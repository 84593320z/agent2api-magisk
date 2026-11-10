#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · 建目录兼容层
#
# 为什么需要这一层：
#   KernelSU 的安装器用 `busybox sh -c <installer>` 跑安装脚本，并注入
#   ASH_STANDALONE=1。standalone 模式下 busybox ash 把 applet 直接跑在自身
#   进程里，此时内置的 `mkdir -p <绝对路径>` 会把路径截断成 "/"，输出
#       mkdir: can't create directory '/': Invalid argument
#   并以 1 退出 —— 绝对路径一律建不出来。2026-11-10 在 KernelSU 3.3.1-44
#   的 OnePlus PJZ110 上逐条实测：相对路径、不带 -p 的 mkdir、以及 sed/awk/
#   cp/rm/chmod/find 等其它 applet 都正常，只有 `mkdir -p <绝对路径>` 坏掉。
#   运行期脚本（post-fs-data.sh / service.sh / a2a）由 ksud 用同一套环境变量
#   拉起，所以这层要同时覆盖"安装"和"运行"两条路径。
#
# 做法：a2a_mkdir 先试内置 mkdir -p；失败再退回"逐级 mkdir"（不带 -p 的
#   mkdir 在 standalone 模式下正常）。最后把 mkdir 换成包装函数，现有
#   所有 `mkdir -p ...` 调用点不用改；不带 -p 的调用原样转给真 mkdir。
#
# 约束：只允许 POSIX sh 语法（见 common.sh 顶部说明）。
# ============================================================================

[ -n "${A2A_MKDIR_SH:-}" ] && return 0
A2A_MKDIR_SH=1

# a2a_mkdir [-p] DIR...：等价于 mkdir -p，失败时把真实错误留在 A2A_MKDIR_ERR。
# 只认 -p/--parents（模块内所有调用点都是这个形式），其它选项直接报错，
# 免得把选项值当成目录名去创建。
a2a_mkdir() {
  A2A_MKDIR_ERR=
  while [ $# -gt 0 ]; do
    case $1 in
      -p|--parents) shift ;;
      -*) A2A_MKDIR_ERR="不支持的 mkdir 选项：$1"; return 2 ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0

  # 快速路径：全部已存在就直接返回，不 fork、不碰 mkdir。
  _a2a_all=1
  for _a2a_d in "$@"; do
    [ -d "$_a2a_d" ] || { _a2a_all=; break; }
  done
  [ -n "$_a2a_all" ] && return 0

  if _a2a_out=$(command mkdir -p "$@" 2>&1); then
    return 0
  fi
  A2A_MKDIR_ERR=$_a2a_out

  # 逐级创建：不带 -p 的 mkdir 不受 standalone 缺陷影响。
  for _a2a_d in "$@"; do
    [ -d "$_a2a_d" ] && continue
    _a2a_rest=$_a2a_d
    case $_a2a_rest in
      /*) _a2a_cur=/ ;;
      *)  _a2a_cur= ;;
    esac
    while [ -n "$_a2a_rest" ]; do
      _a2a_c=${_a2a_rest%%/*}
      case $_a2a_rest in
        */*) _a2a_rest=${_a2a_rest#*/} ;;
        *)   _a2a_rest= ;;
      esac
      case $_a2a_c in
        ''|.) continue ;;
      esac
      if [ -z "$_a2a_cur" ]; then
        _a2a_cur=$_a2a_c
      elif [ "$_a2a_cur" = / ]; then
        _a2a_cur=/$_a2a_c
      else
        _a2a_cur=$_a2a_cur/$_a2a_c
      fi
      [ -d "$_a2a_cur" ] && continue
      if ! _a2a_out=$(command mkdir "$_a2a_cur" 2>&1); then
        [ -d "$_a2a_cur" ] && continue
        A2A_MKDIR_ERR="$_a2a_cur：$_a2a_out"
        return 1
      fi
    done
  done
  return 0
}

# 只接管 `mkdir -p`。不带 -p 的调用必须保留原语义——目标已存在时以非 0 退出，
# 因为 dns.sh 用 `mkdir "$DNS_CACHE.publish.lock"` 当互斥锁，包装函数一旦把
# "已存在" 当成功，并发发布就会同时进入临界区。
mkdir() {
  case ${1:-} in
    -p|--parents) a2a_mkdir "$@" ;;
    *) command mkdir "$@" ;;
  esac
}
