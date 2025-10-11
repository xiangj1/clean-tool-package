# photo_clean_core

极简纯 Dart 批次图像重复 / 相似 / 模糊分类流式核心库（单一公共函数 + 单一事件）。

> 该仓库已扁平化；历史中的 CLI、压缩、加密、目录 JSON 输出、辅助脚本等均已移除，只保留最小必要算法与流式事件接口。

## 公共 API（只有一个）
`analyzeInMemoryStreaming(entries, phashThreshold: 10, blurThreshold: 250, regroupEvery: 50)`

事件类型只有一种：
- `CleanInfoUpdatedEvent`：每达到 `regroupEvery` 数量或结束时输出聚合分类 Map（all / duplicate / similar / blur / screenshot / video / other）。

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

## 设计理念
内部包含感知哈希 / 模糊度 / O(n²) 聚类实现，但它们均为私有；上层只需消费聚合分类事件，避免误用底层算法并方便未来替换实现。

## 流式使用（内存图片）
只会在批次（每 `regroupEvery` 张，默认 50）或最后输出一次聚合分类。
```dart
await for (final ev in analyzeInMemoryStreaming(entries,
  phashThreshold: 8,
  blurThreshold: 250,
  regroupEvery: 50)) {
  // 仅有这一种事件
  final info = (ev as CleanInfoUpdatedEvent).cleanInfo;
  print('processed=${info['all']['count']} duplicate=${info['duplicate']['count']} similar=${info['similar']['count']}');
}
```

## Flutter 最小示例
下面演示：
1. 通过 `image_picker` 选择多张图片
2. 转成 `InMemoryImageEntry`
3. 监听批次事件，展示聚合分类

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
  Map<String, dynamic>? _lastInfo;
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
  setState(() { _running = true; _lastInfo = null; });

    await for (final ev in analyzeInMemoryStreaming(_entries,
        phashThreshold: 8, blurThreshold: 250, regroupEvery: 20)) {
      if (!mounted) break;
      _lastInfo = (ev as CleanInfoUpdatedEvent).cleanInfo;
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
            if (_lastInfo != null) ...[
              Text('Processed: ${_lastInfo!['all']['count']}'),
              Text('Duplicate: ${_lastInfo!['duplicate']['count']}  Similar: ${_lastInfo!['similar']['count']}  Blur: ${_lastInfo!['blur']['count']}'),
            ] else const Text('No batch yet'),
            const SizedBox(height: 12),
            const SizedBox(height: 12),
            Expanded(child: Center(child: Text(_running ? 'Analyzing...' : 'Done')))
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
- `analyzeInMemoryStreaming`：遇到单图解码异常静默跳过；如需要调试/统计可自行 wrap 或 fork。

## CleanInfo 实时分类
每个批次（或结束）会发出一个 `CleanInfoUpdatedEvent`，`cleanInfo` 结构示例：
```json
{
  "all": {"count": 5, "size": 123456, "list": ["a","b","c","d","e"]},
  "duplicate": {"count": 2, "size": 23456, "list": ["a","b"]},
  "similar": {"count": 3, "size": 34567, "list": ["c","d","e"]},
  "blur": {"count": 1, "size": 7890, "list": ["e"]},
  "screenshot": {"count":0, "size":0, "list":[]},
  "video": {"count":0, "size":0, "list":[]},
  "other": {"count": 1, "size": 8888, "list": ["d"]}
}
```
说明：
- duplicate/similar/blur 是“标签”概念，可重叠；`other` = 未命中前三种的剩余条目。
- screenshot / video 为未来扩展占位当前恒为空。
- duplicate：同组内任意 pair 哈希距离=0
- similar：距离>0 且 ≤ 阈值（剔除已标记 duplicate 的条目）
- 每满 `regroupEvery` 或结束时重新聚合与分类
简单消费方式：
```dart
await for (final ev in analyzeInMemoryStreaming(entries)) {
  if (ev is CleanInfoUpdatedEvent) {
    final info = ev.cleanInfo;
    final dupCount = info['duplicate']['count'];
    // 更新 UI ...
  }
}
```

## 开发 / 贡献
```bash
dart test
```

## 版本
当前 `pubspec.yaml` 版本：0.1.0 （首次极简化版本）。若后续继续产生破坏性改动，建议升级至 0.2.0+ 并维护 CHANGELOG。

## License
MIT
