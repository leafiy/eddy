# 02 — Tracer bullet:自研 GIF 编码器,重编码路径切通

**What to build:** 纯 Swift GIF89a 写出器切通全链路:系统解码逐帧位图/逐帧延迟/循环次数,
自研侧完成调色板量化、自写 LZW、容器组装(GCE 延迟、Netscape 循环扩展、透明索引)。
GIF 压缩路径从 ImageIO 编码切换到新编码器。体积不承诺(keep-if-smaller 兜底,"未变化"合法),
验收 = 时序/透明/可解码全部不变量绿灯。ADR《GIF 编码器自研》随本票落盘。

**Blocked by:** None — can start immediately(与 01 并行)

**Status:** implemented — awaiting `swift test` verification on macOS

- [ ] 压缩后帧数、逐帧延迟、循环次数与原件逐项相等(读回比对)
- [ ] 透明样本压缩后仍含透明像素
- [ ] 输出可被系统解码;仅严格更小才替换原件
- [ ] ImageIO 的 GIF 编码分支从代码中移除(死路 A 封死)
- [ ] ADR 落盘
