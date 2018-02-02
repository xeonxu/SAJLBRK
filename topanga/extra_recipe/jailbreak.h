//
//  jailbreak.h
//  extra_recipe
//
//  Created by Abraham Masri @cheesecakeufo on 16/05/2017.
//  Copyright © 2017 Abraham Masri @cheesecakeufo. All rights reserved.
//

#ifndef jailbreak_h
#define jailbreak_h

#include <dlfcn.h>
#include <copyfile.h>
#include <stdio.h>
#include <spawn.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/utsname.h>
#include <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>

// taken from xerub's
typedef uint8_t hash_t[20];

struct topanga_trust_mem {
    uint64_t next; //struct trust_mem *next;
    unsigned char uuid[16];
    unsigned int count;
    hash_t hash[2];
};


extern uint64_t kernel_base;
extern uint64_t kernel_task;
extern uint64_t kaslr_slide;

uint64_t get_proc_for_pid(pid_t target_pid, int spawned);
pid_t get_pid_for_name(char *proc_name);


kern_return_t mount_rootfs(void);
kern_return_t unpack_bootstrap(void);
kern_return_t trust_path(char const *path);
kern_return_t run_path(char const *path);
kern_return_t go_kppless(void);

#endif /* jailbreak_h */
