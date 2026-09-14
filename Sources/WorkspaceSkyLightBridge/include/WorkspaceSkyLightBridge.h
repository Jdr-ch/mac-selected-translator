#pragma once
#include <stdint.h>

/// 提交 Tahoe 的异步跨应用窗口移动；1 表示已提交，0 表示系统缺少接口，-1 表示无法创建操作。
/// 提交不等于移动成功，调用方必须从 WindowServer 回读实际桌面归属。
int WorkspaceSubmitBridgedMove(uint32_t windowID, uint64_t spaceID);
