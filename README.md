# photo_clean_core

极简纯 Dart 图像相似度 / 清晰度 / 重复聚类 核心库。

> 该仓库已扁平化；历史中的 CLI、压缩、加密、目录 JSON 输出、辅助脚本等均已移除，只保留最小必要算法与流式事件接口。

## 功能概览
| 功能 | API | 说明 |
| ---- | ---- | ---- |
| 感知哈希 | `pHash64(image)` | 32→8 DCT 取前 8×8 系数 → 64bit hash |
| 汉明距离 | `hamming64(a,b)` | 计算两个 64bit 哈希差异位数 |
| 清晰度(模糊度) | `laplacianVariance(image)` | 3×3 Laplacian 响应方差（大=清晰）|
| 相似聚类 | `clusterByPhash(hashes, threshold:10)` | O(n²) union-find；阈值内合并 |
| 流式分析 | `analyzeInMemoryStreaming(entries, ...)` | 边解码边发事件；可增量聚类 |

事件类型：
- `ImageAnalyzedEvent`：单张图片完成（含 hash / blurVariance / isBlurry）
- `ClustersUpdatedEvent`：每隔 `regroupEvery` 或结束输出相似分组

## 安装
在你的 `pubspec.yaml`：
```yaml
dependencies:
  photo_clean_core:
    git: https://github.com/xiangj1/clean-tool-package.git
```
然后：
```bash
dart pub get
```

## 快速使用（纯 Dart）
```dart
final hash = pHash64(image);                // BigInt 64bit
final blurVar = laplacianVariance(image);   // double
final clusters = clusterByPhash([hash1, hash2, hash3], threshold: 8);
```

## 流式使用（内存图片）
```dart
await for (final ev in analyzeInMemoryStreaming(entries,
    phashThreshold: 8,
    blurThreshold: 250,
    regroupEvery: 50)) {
  if (ev is ImageAnalyzedEvent) {
    print('hash=${ev.hash.toRadixString(16)} blur=${ev.blurVariance} blurry=${ev.isBlurry}');
  } else if (ev is ClustersUpdatedEvent) {
    print('duplicate groups: ${ev.similarGroups.length}');
  }
}
```

## Flutter 最小示例
下面演示：
1. 通过 `image_picker` 选择多张图片
2. 转成 `InMemoryImageEntry`
3. 监听流式事件，展示模糊/聚类结果

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_clean_core/photo_clean_core.dart';

class DuplicateScanPage extends StatefulWidget {
  const DuplicateScanPage({super.key});
  @override State<DuplicateScanPage> createState() => _DuplicateScanPageState();
}

class _DuplicateScanPageState extends State<DuplicateScanPage> {
  final _entries = <InMemoryImageEntry>[];
  final _duplicates = <List<InMemoryImageEntry>>[];
  int _processed = 0;
  int _blurry = 0;
  bool _running = false;

  Future<void> _pickAndAnalyze() async {
    final picker = ImagePicker();
    final files = await picker.pickMultiImage();
    if (files.isEmpty) return;
    _entries.clear();
    for (final f in files) {
      final bytes = await f.readAsBytes();
      _entries.add(InMemoryImageEntry(f.name, Uint8List.fromList(bytes)));
    }
    setState(() { _running = true; _processed = 0; _blurry = 0; _duplicates.clear(); });

    await for (final ev in analyzeInMemoryStreaming(_entries,
        phashThreshold: 8, blurThreshold: 250, regroupEvery: 20)) {
      if (!mounted) break;
      if (ev is ImageAnalyzedEvent) {
        _processed++;
        if (ev.isBlurry) _blurry++;
      } else if (ev is ClustersUpdatedEvent) {
        _duplicates
          ..clear()
          ..addAll(ev.similarGroups);
      }
      setState(() {});
    }
    if (mounted) setState(() { _running = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Photo Clean Demo')),
      floatingActionButton: FloatingActionButton(
        onPressed: _running ? null : _pickAndAnalyze,
        child: Icon(_running ? Icons.hourglass_bottom : Icons.photo_library),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Processed: $_processed  Blurry: $_blurry  Groups: ${_duplicates.length}'),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: _duplicates.length,
                itemBuilder: (c, i) {
                  final g = _duplicates[i];
                  return ListTile(
                    title: Text('Group ${i+1} (${g.length} images)'),
                    subtitle: Text(g.map((e) => e.name).join(', ')),
                  );
                },
              ),
            )
          ],
        ),
      ),
    );
  }
}
```

要点：
- 目前只提供内存级 API，文件扫描/缓存策略由上层自行实现。
- 大批量 (> 数千) 建议自行分批/隔离 (isolate) 以避免主线程卡顿。

## 性能 & 调参建议
| 场景 | 建议 |
| ---- | ---- |
| 图片数量 > 1k | 提高 `regroupEvery`（如 100 或 200）减少频繁聚类事件 |
| 极大批量 (n>10k) | 先做尺寸/文件大小/扩展名 白名单过滤；再分批调用流式接口 |
| 避免 UI 卡顿 | 在 Flutter 中使用 `compute` / 自建 isolate 分块计算 pHash + blur |
| 增量扫描 | 缓存 (path → hash, blurVar)；新文件追加进数组并仅对新增做 pairwise，或用更高级近似结构（未来可选） |
| 阈值调整 | 一般 5~10 之间，数字越小越“严格” |

复杂度：当前聚类策略是朴素 O(n²)；对 2~3 千张一般仍可接受（取决于设备），更大规模请自行换用 LSH / BK-tree / 分桶预筛。

## API 行为细节
- `pHash64`：默认 32→8 DCT；可调 `size` / `dctSize` 但需保持 `dctSize <= size`。
- `laplacianVariance`：内部自动灰度；过小尺寸 (<3×3) 返回 0。
- `analyzeInMemoryStreaming`：遇到单图解码异常静默跳过；如需要调试/统计可自行 wrap 增强。

## 批处理汇总 (非流式)
如果你不需要事件，而是“一次性得到分类统计（全部 / duplicate / similar / blur / other）”，可以使用：

```dart
final summary = await analyzeInMemorySummary(entries,
  phashThreshold: 8,
  blurThreshold: 250,
);

print(summary.all.count);            // 全部有效图片数量
print(summary.duplicate.count);      // 重复（hash 距离=0）图片数量
print(summary.similar.count);        // 相似但非完全重复的图片数量
print(summary.blur.count);           // 模糊图片数量
print(summary.other.count);          // 未命中上述任一标签的剩余

for (final g in summary.groups) {
  // 每个 g 是一个相似/重复分组 (size>1)
  print('group: '+ g.map((e)=>e.entry.name).join(', '));
}
```

说明：
- 分类是“非互斥”的：同一图片既可能在 duplicate 也可能在 blur；`other` 是未出现在任意 duplicate/similar/blur 集合中的条目。
- `groups` 仅包含 size>1 的聚类结果，用于 UI 展示。
- 初始版本未包含 screenshot / video 分类（将来可扩展）。

## 开发 / 贡献
```bash
dart test
```

## 版本
当前 `pubspec.yaml` 版本：0.1.0 （首次极简化版本）。若后续继续产生破坏性改动，建议升级至 0.2.0+ 并维护 CHANGELOG。

## License
MIT
