#import "WorkspaceSkyLightBridge.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

/// Tahoe 将跨应用移动改为异步操作；这里只封装 Objective-C 私有调用，不管理场景或窗口身份。
/// 接口及符号来源：https://github.com/Hammerspoon/hammerspoon/pull/3889
@interface NSObject (WorkspaceBridgedMove)
- (instancetype)initWithWindows:(NSArray<NSNumber *> *)windows spaceID:(uint64_t)spaceID;
@end

typedef int64_t (*WorkspacePerformOperation)(void *operation);

/// 此接口是本地 Mach-O 符号，dlsym 不导出；按加载镜像的符号表解析，避免硬编码地址或指令偏移。
static void *WorkspaceFindMoveSymbol(void) {
    const char *symbolName = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
    for (uint32_t image = 0; image < _dyld_image_count(); image++) {
        const char *path = _dyld_get_image_name(image);
        if (!path || !strstr(path, "/SkyLight.framework/")) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(image);
        if (!header || header->magic != MH_MAGIC_64) continue;
        const uint8_t *cursor = (const uint8_t *)(header + 1);
        const uint8_t *end = cursor + header->sizeofcmds;
        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *symtab = NULL;
        for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
            if (cursor + sizeof(struct load_command) > end) return NULL;
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) return NULL;
            if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
                if (strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname)) == 0) linkedit = segment;
            }
            if (command->cmd == LC_SYMTAB && command->cmdsize >= sizeof(struct symtab_command)) {
                symtab = (const struct symtab_command *)command;
            }
            cursor += command->cmdsize;
        }
        if (!linkedit || !symtab) return NULL;
        const uintptr_t slide = (uintptr_t)_dyld_get_image_vmaddr_slide(image);
        const uintptr_t base = slide + linkedit->vmaddr - linkedit->fileoff;
        const char *strings = (const char *)(base + symtab->stroff);
        const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
        for (uint32_t index = 0; index < symtab->nsyms; index++) {
            uint32_t offset = symbols[index].n_un.n_strx;
            if (!offset || offset >= symtab->strsize || !symbols[index].n_value) continue;
            if (strncmp(strings + offset, symbolName, symtab->strsize - offset) == 0) {
                return (void *)(slide + symbols[index].n_value);
            }
        }
    }
    return NULL;
}

int WorkspaceSubmitBridgedMove(uint32_t windowID, uint64_t spaceID) {
    // 加载和符号查找仅执行一次；缺失时交由 Swift 适配层选择旧接口并回读结果。
    static WorkspacePerformOperation perform;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        perform = (WorkspacePerformOperation)WorkspaceFindMoveSymbol();
    });
    if (!perform) return 0;
    Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    if (!cls || ![cls instancesRespondToSelector:@selector(initWithWindows:spaceID:)]) return -1;
    id operation = [[cls alloc] initWithWindows:@[@(windowID)] spaceID:spaceID];
    if (!operation) return -1;
    perform((__bridge void *)operation);
    return 1;
}
