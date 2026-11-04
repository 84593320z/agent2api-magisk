#define _GNU_SOURCE
#include <spawn.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <string.h>
#include <errno.h>
extern char **environ;
int main(int argc,char **argv) {
 if(argc>1 && !strcmp(argv[1],"child")) {char cwd[1024]; getcwd(cwd,sizeof cwd); printf("CHILD argv0=%s arg=%s cwd=%s env=%s\n",argv[0],argc>2?argv[2]:"",cwd,getenv("A2A_BRIDGE_TEST")?getenv("A2A_BRIDGE_TEST"):"missing"); return 0;}
 if(argc<3)return 2;
 char *args[]={"original-plugin-argv0","child","space argument",0};
 setenv("A2A_BRIDGE_TEST","preserved",1);
 int pipes[2];if(pipe(pipes))return 3;
 posix_spawn_file_actions_t fa;posix_spawn_file_actions_init(&fa);
 posix_spawn_file_actions_adddup2(&fa,pipes[1],1);
 posix_spawn_file_actions_addclose(&fa,pipes[0]);
 posix_spawn_file_actions_addclose(&fa,pipes[1]);
 posix_spawn_file_actions_addchdir_np(&fa,"/data/local/tmp");
 pid_t pid=0;int r;
 if(!strcmp(argv[1],"spawn")) r=posix_spawn(&pid,argv[2],&fa,0,args,environ);
 else if(!strcmp(argv[1],"spawnp")) r=posix_spawnp(&pid,argv[2],&fa,0,args,environ);
 else {pid=fork(); if(pid==0){close(pipes[0]);dup2(pipes[1],1);close(pipes[1]);chdir("/data/local/tmp"); if(!strcmp(argv[1],"execvp"))execvp(argv[2],args);else if(!strcmp(argv[1],"execv"))execv(argv[2],args);else if(!strcmp(argv[1],"execvpe"))execvpe(argv[2],args,environ);else execve(argv[2],args,environ);perror("exec");_exit(111);}r=pid<0?errno:0;}
 close(pipes[1]);posix_spawn_file_actions_destroy(&fa);
 if(r){printf("SPAWN_ERROR=%d %s\n",r,strerror(r));close(pipes[0]);return 10;}
 char b[4096];ssize_t n;while((n=read(pipes[0],b,sizeof b))>0)fwrite(b,1,n,stdout);close(pipes[0]);
 int status;waitpid(pid,&status,0);printf("STATUS=%d\n",status);return status?11:0;
}
