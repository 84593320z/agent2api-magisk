#!/bin/sh
# 发布签名工具：换掉历史泄露的 keystore，并在打包前挡住它。
#
# 背景（F-011 / RR-12）：仓库历史里曾经提交过 apk-mod/a2a-mod.jks，同一个口令
# 还写在文档里。文件虽然已经从当前树删除，但 git 历史里仍然可以完整取出来
# （`git show 23b881d:apk-mod/a2a-mod.jks`），任何拿到仓库的人都能用它签出
# 一个「和官方同包名、同签名」的 APK —— Android 会当成正常升级静默安装。
# 因此这把钥匙只能按「已泄露」处理：不能再用它签任何新包，并且必须换新钥匙
# 重新发版（跨签名无法覆盖安装，老用户要按 docs/signing.md 做一次迁移）。
#
# 本脚本只做三件事，都可以在没有 Android SDK 的开发机上跑：
#   new               生成新的离线 keystore（默认拒绝写进仓库目录）
#   fingerprint       打印 keystore 证书的 SHA-256
#   check-fingerprint 判断某个 SHA-256 是不是那把泄露的钥匙（是则退出 2）
#
# 用法：
#   sh apk-mod/sign-tool.sh new --out ~/.a2a-signing
#   sh apk-mod/sign-tool.sh fingerprint --keystore ~/.a2a-signing/a2a-release.jks
#   sh apk-mod/sign-tool.sh check-fingerprint B18B0EB2...
set -u

# 泄露的签名证书 SHA-256（不带冒号，大写）。出现这个值就必须拒绝。
BANNED_CERT_SHA256="B18B0EB2078329A9963322E87F47669943655DB857AA06C076DD868365C0BF15"
# 泄露的 keystore 文件本身（git 23b881d:apk-mod/a2a-mod.jks）的 SHA-256。
BANNED_KEYSTORE_SHA256="25cb9dbd9ddae971347f1499bee97bf6bd8f2c64380d973179dac4cb774a472d"

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

die() { printf '%s\n' "$*" >&2; exit 1; }

need_keytool() {
  command -v keytool >/dev/null 2>&1 || die "找不到 keytool：需要 JDK（macOS/Linux 装 openjdk，Windows 装 Temurin JDK）"
}

sha_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "没有 sha256sum / shasum，无法校验 keystore"
  fi
}

# 把 keytool 输出里的 SHA256 指纹抠成 64 位大写十六进制
parse_fp() {
  awk 'toupper($0) ~ /SHA256:/ { sub(/.*SHA256:[ \t]*/, ""); print }' \
    | tr -d ':\r' | tr -d ' \t' | tr 'a-z' 'A-Z' | cut -c1-64
}

cmd_check_fingerprint() {
  [ $# -ge 1 ] || die "用法: check-fingerprint <SHA256>"
  fp=$(printf '%s' "$1" | tr -d ':' | tr -d ' ' | tr 'a-z' 'A-Z')
  if [ "$fp" = "$BANNED_CERT_SHA256" ]; then
    printf '%s\n' "拒绝：这是已泄露的历史签名证书（apk-mod/a2a-mod.jks），不能用于任何新版本。" >&2
    return 2
  fi
  printf '%s\n' "ok: 该指纹不是泄露的那把钥匙"
  return 0
}

cmd_new() {
  out=""
  alias_name="a2a"
  dname="CN=Agent2API Release, OU=Mobile, O=Agent2API, C=CN"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out=${2:-}; shift 2 ;;
      --alias) alias_name=${2:-}; shift 2 ;;
      --dname) dname=${2:-}; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [ -n "$out" ] || die "用法: new --out <目录> [--alias a2a]"
  need_keytool

  # 目录可能是刚创建的空壳；被拒绝时不能留下垃圾
  out_existed=1
  [ -d "$out" ] || out_existed=0
  mkdir -p "$out" || die "无法创建目录: $out"
  out_abs=$(cd "$out" && pwd)
  case "$out_abs/" in
    "$REPO"/*)
      [ "$out_existed" = "0" ] && rmdir "$out" 2>/dev/null
      die "拒绝把签名私钥写进仓库目录（$out_abs 在 $REPO 里）；请换到仓库外面，例如 ~/.a2a-signing"
      ;;
  esac

  ks="$out_abs/a2a-release.jks"
  pwfile="$out_abs/a2a-release.pass"
  [ -e "$ks" ] && die "已存在，未覆盖: $ks"
  [ -e "$pwfile" ] && die "已存在，未覆盖: $pwfile"

  # 32 位随机口令：不落 shell 历史，只写进 600 的口令文件
  if [ -r /dev/urandom ]; then
    pw=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
  else
    pw=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  [ ${#pw} -ge 32 ] || die "随机口令生成失败"

  keytool -genkeypair -keystore "$ks" -storetype PKCS12 -alias "$alias_name" \
    -keyalg RSA -keysize 4096 -validity 10000 -storepass "$pw" -keypass "$pw" \
    -dname "$dname" >/dev/null 2>&1 || die "keytool 生成密钥失败"

  umask 077
  printf '%s\n' "$pw" >"$pwfile" || die "写口令文件失败: $pwfile"
  chmod 600 "$ks" "$pwfile" 2>/dev/null || true

  fp=$(keytool -list -v -keystore "$ks" -alias "$alias_name" -storepass "$pw" 2>/dev/null | parse_fp)
  [ -n "$fp" ] || die "无法读取新证书指纹"
  cmd_check_fingerprint "$fp" >/dev/null || die "新生成的钥匙竟然和泄露的那把撞了指纹，检查 keytool 环境"

  cat <<EOF
已生成新的发布签名：
  keystore   $ks
  口令文件   $pwfile （600，勿入库、勿上传）
  alias      $alias_name
  证书SHA256 $fp

下一步：
  1. 把这两个文件备份到离线介质（丢了就无法给已安装用户发升级包）；
  2. 用下面的环境变量给发布流程喂参数，不要再把口令写进仓库或 CI 日志：
       export A2A_KEYSTORE=$ks
       export A2A_KEY_ALIAS=$alias_name
       export A2A_KEYSTORE_PASS=\$(cat $pwfile)
  3. 按 apk-mod/signing.md 的迁移章节发一次「换签名」版本。
EOF
}

cmd_fingerprint() {
  ks=""; alias_name="a2a"; pass=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --keystore) ks=${2:-}; shift 2 ;;
      --alias) alias_name=${2:-}; shift 2 ;;
      --storepass) pass=${2:-}; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [ -n "$ks" ] || die "用法: fingerprint --keystore <文件> [--alias a2a] [--storepass 口令]"
  [ -f "$ks" ] || die "找不到 keystore: $ks"
  need_keytool

  file_sha=$(sha_of_file "$ks")
  if [ "$file_sha" = "$BANNED_KEYSTORE_SHA256" ]; then
    printf '%s\n' "拒绝：这就是泄露的 keystore 文件（sha256 $file_sha）" >&2
    return 2
  fi

  if [ -z "$pass" ]; then
    pwfile=${A2A_KEYSTORE_PASS_FILE:-}
    if [ -z "$pwfile" ] && [ -f "${ks%.jks}.pass" ]; then
      pwfile="${ks%.jks}.pass"
    fi
    if [ -n "$pwfile" ] && [ -f "$pwfile" ]; then
      pass=$(cat "$pwfile")
    fi
  fi
  [ -n "$pass" ] || die "缺少口令：用 --storepass 或 --storepass-file 之外的方式提供（A2A_KEYSTORE_PASS_FILE）"

  fp=$(keytool -list -v -keystore "$ks" -alias "$alias_name" -storepass "$pass" 2>/dev/null | parse_fp)
  [ -n "$fp" ] || die "读取证书失败（别名或口令不对？）"
  printf '%s\n' "$fp"
  cmd_check_fingerprint "$fp" >/dev/null 2>&1 || {
    printf '%s\n' "警告：这把钥匙属于已泄露的历史证书，不能用于发布。" >&2
    return 2
  }
}

case "${1:-}" in
  new) shift; cmd_new "$@" ;;
  fingerprint) shift; cmd_fingerprint "$@" ;;
  check-fingerprint) shift; cmd_check_fingerprint "$@" ;;
  *)
    cat >&2 <<EOF
用法:
  sh apk-mod/sign-tool.sh new --out <目录> [--alias a2a]
  sh apk-mod/sign-tool.sh fingerprint --keystore <文件> [--alias a2a] [--storepass 口令]
  sh apk-mod/sign-tool.sh check-fingerprint <SHA256>
EOF
    exit 1
    ;;
esac
