/* Android/glibc bridge: loader-scoped preloading, never global LD_PRELOAD.
 * Preserve signed package bytes and posix_spawn file actions/attributes.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#define LOADER "/data/a2a/ld.so"
#ifndef A2A_HOME
#define A2A_HOME "/data/adb/agent2api/"
#endif
#define LIBS A2A_HOME "payload/lib"
#ifndef BRIDGE
#define BRIDGE "/data/adb/modules/agent2api/libexec/plugin-spawn.so"
#endif
#define MAX_ARGS 2048
static int (*real_execve)(const char *,char *const[],char *const[]);
static int (*real_execvp)(const char *,char *const[]);
static int (*real_execvpe)(const char *,char *const[],char *const[]);
static int (*real_spawn)(pid_t *,const char *,const posix_spawn_file_actions_t *,const posix_spawnattr_t *,char *const[],char *const[]);
static int (*real_spawnp)(pid_t *,const char *,const posix_spawn_file_actions_t *,const posix_spawnattr_t *,char *const[],char *const[]);
static int (*real_pidfd_spawnp)(int *,const char *,const posix_spawn_file_actions_t *,const posix_spawnattr_t *,char *const[],char *const[]);
extern char **environ;
__attribute__((constructor)) static void init(void) {
 real_execve=dlsym(RTLD_NEXT,"execve"); real_execvp=dlsym(RTLD_NEXT,"execvp");
 real_execvpe=dlsym(RTLD_NEXT,"execvpe"); real_spawn=dlsym(RTLD_NEXT,"posix_spawn");
 real_spawnp=dlsym(RTLD_NEXT,"posix_spawnp"); real_pidfd_spawnp=dlsym(RTLD_NEXT,"pidfd_spawnp");
}
/* Only explicit absolute plugin/runtime/helper paths, ARM64 LE ELF with glibc
 * interp. Upstream 3.5 installs Bun below data/runtimes, outside the old plugin
 * roots. No PATH interception of Android shell/tools, no executable changes. */
static int eligible(const char *path,char canonical[PATH_MAX]) {
 if(!path || path[0]!='/') return 0;
 if(!realpath(path,canonical)) return 0;
 path=canonical;
 const char *roots[]={A2A_HOME "data/plugins/",A2A_HOME "data/providers/",A2A_HOME "data/kernels/",A2A_HOME "data/runtimes/",A2A_HOME "home/plugins/",0};
 int ok=0; for(int i=0;roots[i];i++) if(!strncmp(path,roots[i],strlen(roots[i]))) ok=1;
 if(!ok || access(path,X_OK)) return 0;
 int fd=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW); if(fd<0) return 0;
 Elf64_Ehdr eh; int match=0;
 if(pread(fd,&eh,sizeof eh,0)!=(ssize_t)sizeof eh || memcmp(eh.e_ident,ELFMAG,SELFMAG) || eh.e_ident[EI_CLASS]!=ELFCLASS64 || eh.e_ident[EI_DATA]!=ELFDATA2LSB || eh.e_machine!=EM_AARCH64 || eh.e_phentsize!=sizeof(Elf64_Phdr) || eh.e_phnum>128) goto done;
 for(unsigned i=0;i<eh.e_phnum;i++) {
  Elf64_Phdr ph; uint64_t off=eh.e_phoff+(uint64_t)i*sizeof ph;
  if(off>INT64_MAX || pread(fd,&ph,sizeof ph,(off_t)off)!=(ssize_t)sizeof ph) break;
  if(ph.p_type==PT_INTERP) {
   char buf[128]={0};
   if(ph.p_filesz<2 || ph.p_filesz>=sizeof buf || ph.p_offset>INT64_MAX) break;
   if(pread(fd,buf,ph.p_filesz,(off_t)ph.p_offset)!=(ssize_t)ph.p_filesz || buf[ph.p_filesz-1]) break;
   match=!strcmp(buf,"/lib/ld-linux-aarch64.so.1") || !strcmp(buf,"/lib64/ld-linux-aarch64.so.1") || !strcmp(buf,LOADER);
   break;
  }
 }
done: close(fd); return match;
}
static int wrap(const char *path,char *const argv[],char **out) {
 size_t n=0; if(argv) while(argv[n]) { if(n>=MAX_ARGS) return E2BIG; n++; }
 size_t j=0;
 out[j++]=LOADER;out[j++]="--argv0";out[j++]=(argv && argv[0])?argv[0]:(char*)path;
 out[j++]="--inhibit-cache";out[j++]="--library-path";out[j++]=LIBS;
 /* Keep the bridge in each wrapped glibc runtime itself, so Bun/plugin children
  * spawned later receive the same treatment. This is loader-local, not an
  * LD_PRELOAD environment variable; bionic children do not inherit it. */
 if(!access(BRIDGE,R_OK)) {out[j++]="--preload";out[j++]=BRIDGE;}
 out[j++]=(char*)path;
 for(size_t i=1;i<n;i++) out[j++]=argv[i]; out[j]=0;return 0;
}
int execvp(const char *file,char *const argv[]) {
 char canonical[PATH_MAX];
 if(eligible(file,canonical)) {char *args[MAX_ARGS+10];int r=wrap(canonical,argv,args);if(r){errno=r;return -1;}return real_execve(LOADER,args,environ);}
 return real_execvp(file,argv);
}
int execve(const char *file,char *const argv[],char *const envp[]) {
 char canonical[PATH_MAX];
 if(eligible(file,canonical)) {char *args[MAX_ARGS+10];int r=wrap(canonical,argv,args);if(r){errno=r;return -1;}return real_execve(LOADER,args,envp);}
 return real_execve(file,argv,envp);
}
int posix_spawnp(pid_t *pid,const char *file,const posix_spawn_file_actions_t *fa,const posix_spawnattr_t *attr,char *const argv[],char *const envp[]) {
 if(!real_spawnp) return ENOSYS;
 char canonical[PATH_MAX];
 if(eligible(file,canonical)) {char *args[MAX_ARGS+10];int r=wrap(canonical,argv,args);if(r)return r;return real_spawnp(pid,LOADER,fa,attr,args,envp);}
 return real_spawnp(pid,file,fa,attr,argv,envp);
}
int pidfd_spawnp(int *pidfd,const char *file,const posix_spawn_file_actions_t *fa,const posix_spawnattr_t *attr,char *const argv[],char *const envp[]) {
 if(!real_pidfd_spawnp) return ENOSYS;
 char canonical[PATH_MAX];
 if(eligible(file,canonical)) {char *args[MAX_ARGS+10];int r=wrap(canonical,argv,args);if(r)return r;return real_pidfd_spawnp(pidfd,LOADER,fa,attr,args,envp);}
 return real_pidfd_spawnp(pidfd,file,fa,attr,argv,envp);
}

int execv(const char *file,char *const argv[]) {
 char canonical[PATH_MAX];
 if(eligible(file,canonical)) {char *args[MAX_ARGS+10];int r=wrap(canonical,argv,args);if(r){errno=r;return -1;}return real_execve(LOADER,args,environ);}
 return real_execve(file,argv,environ);
}
int execvpe(const char *file,char *const argv[],char *const envp[]) {
 char canonical[PATH_MAX];
 if(eligible(file,canonical)) {char *args[MAX_ARGS+10];int r=wrap(canonical,argv,args);if(r){errno=r;return -1;}return real_execve(LOADER,args,envp);}
 return real_execvpe(file,argv,envp);
}
int posix_spawn(pid_t *pid,const char *file,const posix_spawn_file_actions_t *fa,const posix_spawnattr_t *attr,char *const argv[],char *const envp[]) {
 if(!real_spawn) return ENOSYS;
 char canonical[PATH_MAX];
 if(eligible(file,canonical)) {char *args[MAX_ARGS+10];int r=wrap(canonical,argv,args);if(r)return r;return real_spawn(pid,LOADER,fa,attr,args,envp);}
 return real_spawn(pid,file,fa,attr,argv,envp);
}
