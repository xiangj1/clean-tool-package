# Photo Clean Monorepo

Photo Clean 是一个包含核心图像相似度算法与命令行工具的 Dart monorepo，帮助你快速检测相似或模糊的图片。

## Packages

- **photo_clean_core**：纯 Dart 库，封装 pHash、Laplacian 方差与基于哈希的简单聚类算法。
- **photo_clean_cli**：命令行工具，基于 `photo_clean_core`，扫描文件夹中的图片并输出相似分组以及可能的模糊照片。

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
   dart run bin/photo_clean_cli.dart <images_folder> [phash_threshold=10] [blur_threshold=250]
   ```

## Packages 说明

### photo_clean_core

- 目录：`packages/photo_clean_core`
- 依赖：[`image`](https://pub.dev/packages/image) 与 [`collection`](https://pub.dev/packages/collection)
- 核心能力：
  - `pHash64`：对图片进行缩放、灰度化、DCT-II、基于中位数生成 64bit 感知哈希。
  - `hamming64`：计算两个 64bit 哈希的汉明距离。
  - `laplacianVariance`：使用 3x3 Laplacian 核衡量灰度图清晰度。
  - `clusterByPhash`：按阈值聚类（O(n²)），将相似图片分组。
- 在该目录执行 `dart test` 可运行核心库的单元测试。

### photo_clean_cli

- 目录：`packages/photo_clean_cli`
- 依赖：`photo_clean_core`（path 依赖）、`image`、`path`
- 功能：遍历指定目录的图片文件（jpg/jpeg/png/bmp/webp），计算 pHash 与 Laplacian 方差，输出相似分组并标记疑似模糊的图片。
- 在该目录执行 `dart run bin/photo_clean_cli.dart <folder>` 可直接运行。

## 许可证

本项目使用 [MIT License](LICENSE)。
