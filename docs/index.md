# 项目规范索引

本目录存放 Vesper 的产品设计和工程协作规范。规范以简体中文编写，技术名称、API 和代码标识保留英文。

## 文档

- [产品与体验原则](product-and-experience.md)：产品定位、核心任务和体验原则。
- [视觉与交互规范](visual-and-interaction.md)：界面层级、播放器控制和状态反馈原则。
- [技术架构约定](architecture.md)：PlaybackCore、双引擎边界、媒体来源抽象和依赖约束。
- [开发准则](development-guidelines.md)：代码、测试、变更和协作要求。
- [待决事项](open-decisions.md)：需要在实现前共同确认的产品与技术选择。
- [项目计划](project-plan.md)：从技术核验到首版验收的实施阶段和交付条件。
- [开发环境与导航原型](development-setup.md)：构建步骤、原型范围与当前验证状态。

## 维护原则

规范用于减少歧义，不替代具体功能设计。新增决策应同步更新对应文档；影响范围较大的技术选择应记录原因、替代方案和影响。若实现与规范冲突，先判断规范是否过时，再通过修改规范明确新的约定，不要静默偏离。

## 当前基础

Vesper 使用自有 PlaybackCore 调度 AetherEngine 与 SwiftVLC 两个隔离的播放引擎。首发平台仅为 iOS（iPhone），当前构建基线为 iOS 26。具体版本、二进制隔离与许可审核要求见[播放架构](playback.md)。
