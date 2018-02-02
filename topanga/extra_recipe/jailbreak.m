//
//  jailbreak.m
//  topanga
//
//  Created by Abraham Masri @cheesecakeufo on 15/12/2017.
//  Copyright © 2017 Abraham Masri @cheesecakeufo. All rights reserved.
//

#include "jailbreak.h"
#include "libjb.h"
#include "kutils.h"
#include "kcall.h"
#include "symbols.h"
#include "kmem.h"
#include "utilities.h"
#include "amfi_codesign.h"
#include "patchfinder64_11.h"

#include <errno.h>
#include <dirent.h>

uint64_t trust_cache = 0;
uint64_t amficache = 0;

uint64_t containermanagerd_proc = 0;
uint64_t contaienrmanagerd_cred = 0;
uint64_t kernel_trust = 0;


/*
 * Purpose: iterates over the procs and finds our proc
 */
uint64_t get_proc_for_pid(pid_t target_pid, int spawned) {
    
    uint64_t task_self = task_self_addr();

    uint64_t original_struct_task = rk64(task_self + koffset(KSTRUCT_OFFSET_IPC_PORT_IP_KOBJECT));
    
    // go backwards first
    while (original_struct_task != -1) {
        uint64_t bsd_info = rk64(original_struct_task + koffset(KSTRUCT_OFFSET_TASK_BSD_INFO));
        
        // get the process pid
        uint32_t pid = rk32(bsd_info + koffset(KSTRUCT_OFFSET_PROC_PID));
        
        if(pid == target_pid) {
            return bsd_info;
        }

        if(spawned) // spawned binaries will exist AFTER our task
            original_struct_task = rk64(original_struct_task + koffset(KSTRUCT_OFFSET_TASK_NEXT));
        else
            original_struct_task = rk64(original_struct_task + koffset(KSTRUCT_OFFSET_TASK_PREV));
        
    }

    printf("[INFO]: no proc was found for pid: %d\n", target_pid);
    
    return -1; // we failed :/
}

/*
 * Purpose: iterates over the procs and finds a pid with given name
 */
pid_t get_pid_for_name(char *name) {
    
    uint64_t task_self = task_self_addr();
    uint64_t struct_task = rk64(task_self + koffset(KSTRUCT_OFFSET_IPC_PORT_IP_KOBJECT));
    
    
    while (struct_task != 0) {
        uint64_t bsd_info = rk64(struct_task + koffset(KSTRUCT_OFFSET_TASK_BSD_INFO));
        
        char comm[MAXCOMLEN+1];
        kread(bsd_info + 0x268 /* KSTRUCT_OFFSET_PROC_COMM (is this iPhone X offset??) */, comm, 17);

        if(strcmp(name, comm) == 0) {

            // get the process pid
            uint32_t pid = rk32(bsd_info + koffset(KSTRUCT_OFFSET_PROC_PID));
            return (pid_t)pid;
        }
        
        struct_task = rk64(struct_task + koffset(KSTRUCT_OFFSET_TASK_PREV));
        
        if(struct_task == -1)
            return -1;
    }
    return -1; // we failed :/
}

/*
 * Purpose: iterates over the procs and finds a proc with given name
 */
//NSMutableArray *processed_procs;
//uint64_t get_proc_for_name(char *name) {
//    
//    if(processed_procs == nil)
//        processed_procs = [[NSMutableArray alloc] init];
//    
//    uint64_t task_self = task_self_addr();
//    uint64_t struct_task = rk64(task_self + koffset(KSTRUCT_OFFSET_IPC_PORT_IP_KOBJECT));
//    
//    
//    while (struct_task != 0) {
//        uint64_t bsd_info = rk64(struct_task + koffset(KSTRUCT_OFFSET_TASK_BSD_INFO));
//        
//        if([processed_procs containsObject:@(bsd_info)])
//            continue;
//
//        
//        char comm[MAXCOMLEN+1];
//        kread(bsd_info + 0x268 /* KSTRUCT_OFFSET_PROC_COMM (is this iPhone X offset??) */, comm, 17);
//        
//        if(strcmp(name, comm) == 0) {
//            
//            return bsd_info;
//        }
//        
//        struct_task = rk64(struct_task + koffset(KSTRUCT_OFFSET_TASK_PREV));
//        
//        [processed_procs addObject:@(bsd_info)];
//        if(struct_task == -1)
//            return -1;
//    }
//    return -1; // we failed :/
//}


uint64_t our_proc = 0;
uint64_t our_cred = 0;

void set_uid0 () {
    
    kern_return_t ret = KERN_SUCCESS;
    
    if(our_proc == 0)
        our_proc = get_proc_for_pid(getpid(), false);
    
    if(our_proc == -1) {
        printf("[ERROR]: no our proc. wut\n");
        ret = KERN_FAILURE;
        return;
    }
    
    extern uint64_t kernel_task;
    
    uint64_t kern_ucred = kread_uint64(kernel_task + 0x100 /* KSTRUCT_OFFSET_PROC_UCRED */);
    
    if(our_cred == 0)
        our_cred = kread_uint64(our_proc + 0x100 /* KSTRUCT_OFFSET_PROC_UCRED */);
    
    kwrite_uint64(our_proc + 0x100 /* KSTRUCT_OFFSET_PROC_UCRED */, kern_ucred);
    
    uint64_t offsetof_p_csflags = 0x2a8;
    
    uint32_t csflags = kread_uint32(our_proc + offsetof_p_csflags);
    kwrite_uint32(our_proc + offsetof_p_csflags, (csflags | CS_PLATFORM_BINARY | CS_INSTALLER | CS_GET_TASK_ALLOW) & ~(CS_RESTRICT | CS_KILL | CS_HARD));
    
    setuid(0);
    
}

void set_cred_back () {
    kwrite_uint64(our_proc + 0x100 /* KSTRUCT_OFFSET_PROC_UCRED */, our_cred);
}



kern_return_t mount_rootfs() {
    
    kern_return_t ret = KERN_SUCCESS;
    
    NSLog(@"kaslr_slide: %llx\n", kaslr_slide);
    NSLog(@"passing kernel_base: %llx\n", kernel_base);
    
    int rv = init_kernel(kernel_base, NULL);
    
    if(rv != 0) {
        NSLog(@"[ERROR]: could not initialize kernel\n");
        ret = KERN_FAILURE;
        return ret;
    }
    
    NSLog(@"[INFO]: sucessfully initialized kernel\n");
    
    uint64_t rootvnode = find_rootvnode();
    NSLog(@"_rootvnode: %llx (%llx)\n", rootvnode, rootvnode - kaslr_slide);
    
    if(rootvnode == 0) {
        ret = KERN_FAILURE;
        return ret;
    }
    
    uint64_t rootfs_vnode = kread_uint64(rootvnode);
    NSLog(@"rootfs_vnode: %llx\n", rootfs_vnode);
    uint64_t v_mount = kread_uint64(rootfs_vnode + 0xd8);
    NSLog(@"v_mount: %llx (%llx)\n", v_mount, v_mount - kaslr_slide);
    uint32_t v_flag = kread_uint32(v_mount + 0x71);
    NSLog(@"v_flag: %x (%llx)\n", v_flag, v_flag - kaslr_slide);
    kwrite_uint32(v_mount + 0x71, v_flag & ~(1 << 6));

    set_uid0();
    printf("our uid: %d\n", getuid());
    char *nmz = strdup("/dev/disk0s1s1");
    rv = mount("hfs", "/", MNT_UPDATE, (void *)&nmz);
    
    if(rv == -1) {
        printf("[ERROR]: could not mount '/': %d\n", rv);
    } else {
        printf("[INFO]: successfully mounted '/'\n");
    }
    

    return ret;
}

kern_return_t unpack_bootstrap() {
    
    kern_return_t ret = KERN_SUCCESS;

    char path[4096];
    uint32_t size = sizeof(path);
    _NSGetExecutablePath(path, &size);
    char *pt = realpath(path, NULL);
    
    NSString *execpath = [[NSString stringWithUTF8String:pt] stringByDeletingLastPathComponent];

    NSString *bootstrap_path = [execpath stringByAppendingPathComponent:@"bootstrap.tar"];
    NSString *bootstrap_2_path = [execpath stringByAppendingPathComponent:@"bootstrap_2.tar"];
    NSString *cydia64_path = [execpath stringByAppendingPathComponent:@"cydia64.tar"];
    NSString *tweaksupport_path = [execpath stringByAppendingPathComponent:@"tweaksupport.tar"];
    
    #if DEBUG
    int signature = -1;
    #else
    int signature = open("/.installed_topanga", O_RDONLY);
    #endif
    
    if (signature == -1) {

        chdir("/");
        FILE *bootstrap = fopen([bootstrap_path UTF8String], "r");
        untar(bootstrap, "/");
        fclose(bootstrap);
        
        chdir("/");
        FILE *bootstrap_2 = fopen([bootstrap_2_path UTF8String], "r");
        untar(bootstrap_2, "/");
        fclose(bootstrap_2);
        
        chdir("/");
        FILE *tweaksupport = fopen([tweaksupport_path UTF8String], "r");
        untar(tweaksupport, "/");
        fclose(tweaksupport);
    
        // temp (install latest Cydia)
        chdir("/");
        FILE *cydia64 = fopen([cydia64_path UTF8String], "r");
        untar(cydia64, "/");
        fclose(cydia64);

        // Show hidden apps
        NSMutableDictionary* md = [[NSMutableDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/com.apple.springboard.plist"];
        [md setObject:[NSNumber numberWithBool:YES] forKey:@"SBShowNonDefaultSystemApps"];
        [md writeToFile:@"/var/mobile/Library/Preferences/com.apple.springboard.plist" atomically:YES];

        // NO to Cydia stashing
        open("/.cydia_no_stash", O_RDWR | O_CREAT);
        
        // Add our signature
        open("/.installed_topanga", O_RDWR | O_CREAT);
        
        chmod("/private", 0777);
        chmod("/private/var", 0777);
        chmod("/private/var/tmp", 0777);
        chmod("/private/var/mobile", 0777);
        chmod("/private/var/mobile/Library", 0777);
        chmod("/private/var/mobile/Library/Caches/", 0777);
        chmod("/private/var/mobile/Library/Preferences", 0777);
        
        set_cred_back();
        extern void uicache(void);
        uicache(); // used to show Cydia.app
        set_uid0();
        
        char *path = "/var/mobile/Library/Caches";
        
        DIR *mydir;
        struct dirent *myfile;
        
        int fd = open(path, O_RDONLY, 0);
        
        
        mydir = fdopendir(fd);
        while((myfile = readdir(mydir)) != NULL) {
            
            NSString *file_name = [NSString stringWithFormat:@"%s", strdup(myfile->d_name)];
            if ([file_name containsString:@".csstore"]) {
                
                NSLog(@"[INFO]: deleting csstore: %@", file_name);
                
                NSString *full_path = [NSString stringWithFormat:@"%s/%@", path, file_name];
                unlink(strdup([full_path UTF8String]));
                
            }
            
        }
        
        closedir(mydir);
        close(fd);
        
        // kill lsd
        pid_t lsd_pid = get_pid_for_name("lsd");
        kill(lsd_pid, SIGKILL);
        
        pid_t lsdiconsservice_pid = get_pid_for_name("lsdiconservice");
        kill(lsdiconsservice_pid, SIGKILL);
        
        // remove caches
        unlink("/var/mobile/Library/Caches/com.apple.springboard-imagecache-icons");
        unlink("/var/mobile/Library/Caches/com.apple.springboard-imagecache-icons.plist");
        unlink("/var/mobile/Library/Caches/com.apple.springboard-imagecache-smallicons");
        unlink("/var/mobile/Library/Caches/com.apple.springboard-imagecache-smallicons.plist");
        
        unlink("/var/mobile/Library/Caches/SpringBoardIconCache");
        unlink("/var/mobile/Library/Caches/SpringBoardIconCache-small");
        unlink("/var/mobile/Library/Caches/com.apple.IconsCache");
        
        
        // kill installd
        pid_t installd_pid = get_pid_for_name("installd");
        kill(installd_pid, SIGKILL);
        
    }

//    char * original_dir_path = "/Applications/Cydia.app";
//
//    DIR *mydir;
//    struct dirent *myfile;
//
//    int fd = open(original_dir_path, O_RDONLY, 0);
//
//    mydir = fdopendir(fd);
//    while((myfile = readdir(mydir)) != NULL) {
//
//        if(strcmp(myfile->d_name, ".") == 0 || strcmp(myfile->d_name, "..") == 0)
//            continue;
//
//        printf("[FILE]: %s\n", myfile->d_name);
//        chmod(strdup([[NSString stringWithFormat:@"/Applications/Cydia.app/%s", myfile->d_name] UTF8String]), 0777);
//        chown(strdup([[NSString stringWithFormat:@"/Applications/Cydia.app/%s", myfile->d_name] UTF8String]), 0, 0);
//    }

    printf("[INFO]: finished installing bootstrap and friends\n");

    // "fix" containermanagerd
    containermanagerd_proc = get_proc_for_pid(get_pid_for_name("containermanager"), false);
    
    if(containermanagerd_proc == -1) {
        printf("[ERROR]: no containermanagerd. wut\n");
        ret = KERN_FAILURE;
        return ret;
    }
    
    printf("[INFO]: got containermanagerd's proc: %llx\n", containermanagerd_proc);
    
    // fix containermanagerd
    contaienrmanagerd_cred = kread_uint64(containermanagerd_proc + 0x100 /* KSTRUCT_OFFSET_PROC_UCRED */);
    printf("[INFO]: got containermanagerd's ucred: %llx\n", contaienrmanagerd_cred);

    extern uint64_t kernel_task;
    uint64_t kern_ucred = kread_uint64(kernel_task + 0x100 /* KSTRUCT_OFFSET_PROC_UCRED */);
    kwrite_uint64(containermanagerd_proc + 0x100 /* KSTRUCT_OFFSET_PROC_UCRED */, kern_ucred);
    
    trust_cache = find_trustcache();
    amficache = find_amficache();
    
    printf("trust_cache = 0x%llx\n", trust_cache);
    printf("amficache = 0x%llx\n", amficache);

    // we're just doing Cydia for now..
    ret = trust_path("/Applications/Cydia.app");
//    ret = trust_path("/bin");
//    ret = trust_path("/usr/bin");
//    ret = trust_path("/usr/libexec/cydia");
    
//    extern void start_jailbreakd(void);
//    start_jailbreakd();
    
//    ret = run_path("/Applications/Cydia.app/uicache");

    // we probably don't want to do this for now..
    if (containermanagerd_proc) {
        kwrite_uint64(containermanagerd_proc + 0x100 /* KSTRUCT_OFFSET_PROC_UCRED */, contaienrmanagerd_cred);
        printf("[INFO]: gave containermanager its original creds\n");
    }

    exit(0);
    // respring
//    pid_t backboardd_pid = get_pid_for_name("backboardd");
//    printf("[INFO]: killing backboardd\n");
//    kill(backboardd_pid, SIGKILL);
    
    return ret;
}


kern_return_t trust_path(char const *path) {
    
    kern_return_t ret = KERN_SUCCESS;
    extern mach_port_t tfp0;
    
#define USE_LIBJB
#ifdef USE_LIBJB
    
    struct trust_mem mem;
    mem.next = kread_uint64(trust_cache);
    *(uint64_t *)&mem.uuid[0] = 0xabadbabeabadbabe;
    *(uint64_t *)&mem.uuid[8] = 0xabadbabeabadbabe;
    
    int rv = grab_hashes(path, kread, amficache, mem.next);
    printf("rv = %d, numhash = %d\n", rv, numhash);
    
    size_t length = (sizeof(mem) + numhash * 20 + 0xFFFF) & ~0xFFFF;
    
    if(kernel_trust == 0) {
        ret = mach_vm_allocate(tfp0, (mach_vm_address_t *)&kernel_trust, length, VM_FLAGS_ANYWHERE);
        if(ret != KERN_SUCCESS) {
            printf("[ERROR]: failed to allocate memory\n");
            exit(0);
        }
    }
    printf("alloced: 0x%zx => 0x%llx\n", length, kernel_trust);
    
    mem.count = numhash;
    kwrite(kernel_trust, &mem, sizeof(mem));
    kwrite(kernel_trust + sizeof(mem), allhash, numhash * 20);
    kwrite_uint64(trust_cache, kernel_trust);
    printf("[INFO]: wrote trust cache\n");
    
#else
    
    struct topanga_trust_mem topanga_mem;
    topanga_mem.next = kread_uint64(trust_cache);
    *(uint64_t *)&topanga_mem.uuid[0] = 0xabadbabeabadbabe;
    *(uint64_t *)&topanga_mem.uuid[8] = 0xabadbabeabadbabe;
    
    uint8_t *amfi_hash = amfi_grab_hashes(path);
    memmove(topanga_mem.hash[0], amfi_hash, 20);
    topanga_mem.count += 1;
    
    if(kernel_task == 0) {
        ret = mach_vm_allocate(tfp0, (mach_vm_address_t *)&kernel_trust, sizeof(topanga_mem), VM_FLAGS_ANYWHERE);
        if(ret != KERN_SUCCESS) {
            printf("[ERROR]: failed to allocate memory\n");
            exit(0);
        }
    }
    

    kwrite(kernel_trust, &topanga_mem, sizeof(topanga_mem));
    kwrite_uint64(trust_cache, kernel_trust);
    printf("[INFO]: wrote trust cache\n");
    sleep(1);
    
#endif
    
    return ret;
}

kern_return_t run_path(const char *path) {
    
    kern_return_t ret = KERN_SUCCESS;
    
    pid_t pd;
    posix_spawn(&pd, path, NULL, NULL, (char **)&(const char*[]){path, NULL }, NULL);
    
    printf("uicache: %d\n", pd);
    uint64_t proc = get_proc_for_pid(pd, true);
    
    printf("proc: %llx\n", proc);

    uint32_t csflags = kread_uint32(proc  + 0x2a8 /* csflags */);
    csflags = (csflags | CS_PLATFORM_BINARY | CS_INSTALLER | CS_GET_TASK_ALLOW) & ~(CS_RESTRICT | CS_KILL | CS_HARD);
    kwrite_uint32(proc  + 0x2a8 /* csflags */, csflags);
    
    printf("empower\n");

    
    waitpid(pd, NULL, 0);
    
    return ret;
}

/*
 
trust cache (iOS 10.x/iPad Air):
 
(0): search for string 'amfi_prevent_old_entitled_platform'
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CD8 loc_FFFFFFF0064F8CD8                    ; CODE XREF: sub_FFFFFFF0064F8ADC+1D8↑j
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CD8                 ADRP            X0, #aAmfiPreventOld@PAGE ; "amfi_prevent_old_entitled_platform_bina"...
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CDC (1)             ADD             X0, X0, #aAmfiPreventOld@PAGEOFF ; "amfi_prevent_old_entitled_platform_bina"...
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CE0                 MOV             W2, #4
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CE4                 ADD             X1, SP, #0x50+var_34
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CE8                 BL              sub_FFFFFFF0064FAA60
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CEC (2)             CBZ             W0, loc_FFFFFFF0064F8D00 (3)
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CF0                 LDR             W8, [SP,#0x50+var_34]
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CF4                 CBZ             W8, loc_FFFFFFF0064F8D00
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CF8                 MOV             W8, #1
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8CFC                 STRB            W8

com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8D00 loc_FFFFFFF0064F8D00 (3)                    ; CODE XREF: sub_FFFFFFF0064F8ADC+A0↑j
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8D00                                 ; sub_FFFFFFF0064F8ADC+210↑j ...
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8D00                 BL              sub_FFFFFFF0064F6508 (4)
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F8D04                 BL              sub_FFFFFFF0064FAA00

com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6508 sub_FFFFFFF0064F6508 (4)                  ; CODE XREF: sub_FFFFFFF0064F8ADC:loc_FFFFFFF0064F8D00↓p
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6508
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6508 var_s0          =  0
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6508
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6508                 STP             X29, X30, [SP,#-0x10+var_s0]!
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F650C                 MOV             X29, SP
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6510                 ADRP            X8, #qword_FFFFFFF00761B328@PAGE (5) the address of the QWORD is trust cache
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6514                 STR             XZR, [X8,#qword_FFFFFFF00761B328@PAGEOFF]
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6518                 BL              sub_FFFFFFF0064FAA00
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F651C                 ADRP            X8, #qword_FFFFFFF00761B320@PAGE
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6520                 STR             X0, [X8,#qword_FFFFFFF00761B320@PAGEOFF]
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6524                 LDP             X29, X30, [SP+var_s0],#0x10
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6528                 RET
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6528 ; End of function sub_FFFFFFF0064F6508
 
 
 
trust cache (iOS 11.x / iPhone X):
 
(0): com.apple.driver.AppleMobileFileIntegrity:__bss there will be a list of qwords
(1): check the ref(s) to each one (choose the first ref ADRP)
(2): if the func is like this then and your QWORD is the first one in the func then it's the correct one!

com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6508 sub_FFFFFFF0064F6508                    ; CODE XREF: sub_FFFFFFF0064F8ADC:loc_FFFFFFF0064F8D00↓p
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6508
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6508 var_s0          =  0
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6508
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6508                 STP             X29, X30, [SP,#-0x10+var_s0]!
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F650C                 MOV             X29, SP
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6510                 ADRP            X8, #qword_FFFFFFF00761B328@PAGE <-----
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6514                 STR             XZR, [X8,#qword_FFFFFFF00761B328@PAGEOFF]
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6518                 BL              sub_FFFFFFF0064FAA00
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F651C                 ADRP            X8, #qword_FFFFFFF00761B320@PAGE
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6520                 STR             X0, [X8,#qword_FFFFFFF00761B320@PAGEOFF]
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6524                 LDP             X29, X30, [SP+var_s0],#0x10
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6528                 RET
com.apple.driver.AppleMobileFileIntegrity:__text:FFFFFFF0064F6528 ; End of function sub_FFFFFFF0064F6508
 
 */


