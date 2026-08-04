# GIF 编码器自研,拒绝 ImageIO 编码与 GPL 工具链

GIF 压缩此前数版失败,根因是 ImageIO 的 GIF 编码器:每帧写全幅图、调色板不优化、
无帧间差分,输出几乎必然大于输入,在 keep-if-smaller 语义下表现为永远"未变化"。
现成的替代品 gifsicle(GPLv2)与 libimagequant 一样被本项目的授权立场排除
(见 THIRD_PARTY_NOTICES,App 哲学为全引擎内置、零 GPL 依赖)。

决定:GIF 编码完全自研(纯 Swift GIF89a 写出器——全局调色板中位切分、Bayer 有序
抖动、帧间差分 + 透明像素复用、有损吸附、自写 LZW),ImageIO 仅保留解码职责。
管线为二遍流式,内存与帧数无关。

后果:LZW 与容器写出逻辑由本仓库自行维护;换取的是可控的压缩率、动画与时序的
硬保证、以及无授权风险。半年后有人建议"直接用 gifsicle"时,请先读本文件。
