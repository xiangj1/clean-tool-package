# photo_clean_core

纯 Dart 图像处理工具库，提供感知哈希、汉明距离、Laplacian 方差与基于哈希的简单聚类函数。

## 功能

- `pHash64(img.Image image, {int size = 32, int dctSize = 8})`：计算 64 bit 感知哈希。
- `hamming64(BigInt a, BigInt b)`：计算 64 bit 哈希之间的汉明距离。
- `laplacianVariance(img.Image image)`：使用 3×3 Laplacian kernel 计算图像清晰度指标。
- `clusterByPhash(List<BigInt> hashes, {int threshold = 10})`：O(n²) 的简单聚类，汉明距离小于等于阈值时归为同一组。

## 开发

```bash
cd packages/photo_clean_core
dart pub get
dart test
```
