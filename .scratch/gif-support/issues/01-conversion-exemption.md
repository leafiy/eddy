# 01 — 转换豁免:动画资产不再被拍扁

**What to build:** 用户选择 PNG/JPEG 输出格式时,帧数 >1 的输入(动画资产)不参与格式转换,
仍按原生格式走原地压缩路径;静态单帧 GIF 照常转换。用户批量拖入混合文件夹后,动图永远不会
被静默拍扁成首帧静态图并删除原件。

**Blocked by:** None — can start immediately

**Status:** implemented — awaiting `swift test` verification on macOS

- [ ] 动画 GIF + PNG 输出设置 → 产物仍为 .gif,帧数与原件一致,原件路径不变
- [ ] 静态单帧 GIF + PNG 输出设置 → 产物为 .png,原 .gif 被移除
- [ ] 测试打在压缩入口缝(文件进、文件出),不触碰编码器内部
