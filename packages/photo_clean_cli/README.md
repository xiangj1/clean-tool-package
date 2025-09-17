# photo_clean_cli

命令行工具，用于扫描目录中的图片并寻找相似或模糊的文件。依赖 `photo_clean_core` 中的算法实现。

## 安装依赖

在仓库根目录执行：

```bash
dart pub get
```

## 使用方式

在 `packages/photo_clean_cli` 目录下运行：

```bash
dart run bin/photo_clean_cli.dart <images_folder> [phash_threshold=10] [blur_threshold=250]
```

参数说明：

- `images_folder`：需要扫描的图片目录。
- `phash_threshold`：相似图片聚类的汉明距离阈值，默认 10。
- `blur_threshold`：Laplacian 方差阈值，小于该值的图片会被判定为模糊，默认 250。

程序将输出：

- 成功处理的图片数量以及跳过的文件数量。
- 根据感知哈希聚类得到的相似图片分组。
- 疑似模糊的图片列表。
