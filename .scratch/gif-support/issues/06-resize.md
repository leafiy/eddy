# 06 — 尺寸压缩:maxWidth 作用于动画资产

**What to build:** 用户设定最大宽度后,GIF 全帧统一等比缩小(作用于合成后的完整画布),
永不放大;缩放后时序与透明不变量全部成立。

**Blocked by:** 02

**Status:** implemented — awaiting `swift test` verification on macOS

- [ ] 输出画布宽 = min(原宽, 设定值),高按比例,全帧一致
- [ ] 原宽 ≤ 设定值时尺寸不变(不放大)
- [ ] 缩放样本的帧数/延迟/循环不变量绿灯
