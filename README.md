# Photo Clean Monorepo

Photo Clean 是一个包含核心图像相似度/质量检测、媒体压缩与图片加密功能的 Dart monorepo，帮助你：
1. 检测相似或模糊图片
2. 压缩图片与视频减小体积
3. 对图片（任意二进制文件亦可）进行加密/解密（AES-GCM + scrypt）

## Packages

- **photo_clean_core**：纯 Dart 库，封装 pHash、Laplacian 方差、聚类、图片压缩与 AES-GCM 加密工具。
- **photo_clean_cli**：命令行工具，基于 `photo_clean_core`，提供相似/模糊分析、媒体压缩与图片加解密子命令。

## 快速开始

1. 安装 Dart SDK (>= 3.5.0)。
2. 在仓库根目录执行依赖安装：
   ```bash
   dart pub get
   ```
3. 运行测试：
   ```bash
   dart test
   ```
4. 执行命令行工具（自动代理到 `packages/photo_clean_cli`）：
   ```bash
   # 分析相似/模糊图片（旧用法兼容）
   dart run bin/photo_clean_cli.dart <images_folder> [phash_threshold=10] [blur_threshold=250]

   # 使用子命令 analyze（等价）
   dart run bin/photo_clean_cli.dart analyze <images_folder> [phash_threshold=10] [blur_threshold=250]

   # 新增：压缩图片与视频（需要本地安装 ffmpeg 以处理视频）
   dart run bin/photo_clean_cli.dart compress <input_path> \
     --out build/compressed \
     --quality 82 \
     --max-width 1920 --max-height 1080 \
     --format auto \
     --video-crf 28
   ```

## Packages 说明

### photo_clean_core

- 目录：`packages/photo_clean_core`
- 依赖：[`image`](https://pub.dev/packages/image)、[`collection`](https://pub.dev/packages/collection)、[`pointycastle`](https://pub.dev/packages/pointycastle)
- 核心能力：
  - `pHash64`：对图片进行缩放、灰度化、DCT-II、基于中位数生成 64bit 感知哈希。
  - `hamming64`：计算两个 64bit 哈希的汉明距离。
  - `laplacianVariance`：使用 3x3 Laplacian 核衡量灰度图清晰度。
   - `clusterByPhash`：按阈值聚类（O(n²)），将相似图片分组。
   - 图片压缩：`compressImageBytes` + `ImageCompressionOptions`
   - 图片/任意数据加密：`encryptBytesToBase64Envelope`
   - 图片/任意数据解密：`decryptBytesFromBase64Envelope`
- 在该目录执行 `dart test` 可运行核心库的单元测试。

### photo_clean_cli

- 目录：`packages/photo_clean_cli`
- 依赖：`photo_clean_core`（path 依赖）、`image`、`path`
- 功能：
   - `analyze`：遍历指定目录的图片文件（jpg / jpeg / png / bmp），计算 pHash 与 Laplacian 方差，输出相似分组与潜在模糊图片。
   - `compress`：
      - 图片：按需缩放、自动或指定格式（auto / jpeg / png），若体积不减且未缩放则保持原文件。
      - 视频：调用本地 `ffmpeg`，使用 H.264(`libx264`) + CRF；输出 `_compressed.mp4`。
   - `encrypt` / `decrypt`：对图片（或任何文件）进行 AES-GCM + scrypt 加密/解密，输出单一 Base64 文本信封文件（`.enc.txt`）。
   - 输出目录通过 `--out` 指定；未指定时就地生成（加密：添加 `.enc.txt`；解密：添加 `.dec` 后缀）。
- 压缩示例：
   ```bash
      dart run bin/photo_clean_cli.dart compress pictures --out build/compressed --quality 80 --max-width 1920 --format auto --video-crf 26
   ```

### 压缩实现说明

图片压缩基于 `image` 包：
- 按需缩放（保持纵横比）
- 自动格式策略会尝试 `jpeg` 与 `png` 取体积更小者（后续可扩展 webp）
- 若既未缩放也未减小体积，则默认返回原文件（避免质量无意义损失）

视频压缩通过 `ffmpeg`：
- 需要自行安装：`sudo apt-get install -y ffmpeg` 或访问官网
- 使用 `libx264 + CRF`，可通过 `--video-crf` 指定（数值越低画质越高，常用 18~30）
- 输出为 mp4 容器（后缀 `_compressed.mp4`）
- 在该目录执行 `dart run bin/photo_clean_cli.dart <folder>` 可直接运行。

### 加密 / 解密说明

加密使用：AES-256-GCM + scrypt(KDF 参数 N=16384,r=8,p=1, 输出 32 bytes)。

Envelope 内部 JSON（再整体 Base64）：
```jsonc
{
   "alg": "AES-GCM",
   "kdf": "scrypt",
   "salt": "<Base64>",
   "iv": "<Base64>",
   "cipher": "<Base64>",
   "tag": "<Base64>",
   "v": 1
}
```
CLI 仅输出最外层 Base64，方便复制/存储。

示例：
```bash
# 加密整个目录
dart run bin/photo_clean_cli.dart encrypt pictures --password mySecret --out encrypted

# 解密
dart run bin/photo_clean_cli.dart decrypt encrypted --password mySecret --out restored
```

恢复文件默认加 `.dec` 后缀，若需保留原扩展，可自行重命名或后续扩展 envelope 字段（可加 originalExt）。

安全提示：
- 请使用足够复杂的 password；当前未做密码强度校验。
- scrypt 参数可调整（未来可加入 CLI 参数）。
- 未做重复加密检测或时间戳，可按需求扩展。
- 如需合规/高安全场景，请增加完整性外层签名（例如 HMAC 或公私钥签名）。

## 许可证

本项目使用 [MIT License](LICENSE)。
