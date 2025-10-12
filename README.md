# photo_clean_core

极简纯 Dart 批次图像重复 / 相似 / 模糊分类流式核心库（单一公共函数 + 单一事件）。

> 该仓库已扁平化；历史中的 CLI、压缩、加密、目录 JSON 输出、辅助脚本等均已移除，只保留最小必要算法与流式事件接口。

## 公共 API（只有一个）
`analyzeInMemoryStreaming(entries, phashThreshold: 10, blurThreshold: 250, regroupEvery: 50)`

事件类型只有一种：
- `CleanInfoUpdatedEvent`：每达到 `regroupEvery` 数量或结束时输出聚合分类 Map（all / duplicate / similar / blur / screenshot / video / other）。

可选媒体类型：构造 `InMemoryImageEntry` 时指定 `type: MediaType.screenshot` 或 `MediaType.video`，分类会自动进入对应分组；未指定默认为 `image` 不占用 screenshot / video 名额。

## 构建 InMemoryImageEntry（Host 侧集成指引）
库本身不读取文件系统，也不做“这是不是截图/视频”的推断——完全由调用方注入。建议：

1. 统一抽象：在你的采集层产出 `List<InMemoryImageEntry>`（或增量 append），然后交给 `analyzeInMemoryStreaming`。
2. 媒体类型判定策略（示例，可按需替换）：
   - Screenshot：文件名含 `Screenshot` / `屏幕截图` / `WeChat_Screenshot` / 典型前缀；或长宽比接近屏幕分辨率；或来自系统截图目录。
   - Video（封面帧）：扩展名在 `['.mp4', '.mov', '.mkv', '.avi']`，先用你自己的逻辑截取首帧/中帧，再把该帧的二进制作为 `bytes`，并标记 `MediaType.video`。
   - 普通图片：其余全部 `MediaType.image`（默认值，可不显式给）。
3. 大量文件处理：自行分页（例如 1k 一页）构建并依次传给流式接口；或预先过滤（尺寸 / 最小字节数 / 扩展名白名单）。

### 示例：从文件路径批量构建
```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:photo_clean_core/photo_clean_core.dart';

final _screenshotNameHints = [
  'screenshot', '屏幕截图', 'screen_shot', '截屏'
];
final _videoExt = {'.mp4', '.mov', '.mkv', '.avi'};

MediaType _inferType(File f) {
  final nameLower = f.path.toLowerCase();
  if (_videoExt.any((e) => nameLower.endsWith(e))) return MediaType.video;
  if (_screenshotNameHints.any((h) => nameLower.contains(h))) return MediaType.screenshot;
  return MediaType.image;
}

Future<List<InMemoryImageEntry>> buildEntries(Iterable<File> files) async {
  final list = <InMemoryImageEntry>[];
  for (final f in files) {
    try {
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) continue; // 跳过空文件
      list.add(
        InMemoryImageEntry(
          f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : f.path,
          Uint8List.fromList(bytes),
          type: _inferType(f),
        ),
      );
    } catch (_) {
      // 读取失败静默忽略（可在此计数或打印日志）
    }
  }
  return list;
}

Future<void> runClean(Iterable<File> files) async {
  final entries = await buildEntries(files);
  await for (final ev in analyzeInMemoryStreaming(entries,
      phashThreshold: 8, blurThreshold: 250, regroupEvery: 80)) {
    final info = (ev as CleanInfoUpdatedEvent).cleanInfo;
    print('dup=${info['duplicate']['count']} screenshot=${info['screenshot']['count']} video=${info['video']['count']}');
  }
}
```

### 示例：处理视频生成封面帧
如果你需要把视频纳入“相似 / 重复”判断，可自行提前抽帧：
```dart
// 伪代码：使用你偏好的视频处理库 (ffmpeg/flutter_ffmpeg 等)
Uint8List extractMiddleFrameBytes(String videoPath) {
  // 1. 读取总时长
  // 2. 抽取中点帧到内存
  // 3. 返回其 PNG/JPEG 编码字节
  return Uint8List(0);
}

InMemoryImageEntry toVideoEntry(String videoPath) {
  final frameBytes = extractMiddleFrameBytes(videoPath);
  return InMemoryImageEntry(
    videoPath.split('/').last,
    frameBytes,
    type: MediaType.video,
  );
}
```

注意：视频抽帧质量/时间点会影响感知哈希结果；若需要更稳健的相似度，可抽多帧做 hash 取中位数或最小距离（可在上层实现后再只传一条代表帧进入本库）。

### 何时更新条目列表
`analyzeInMemoryStreaming` 当前设计为一次性输入（不可动态 push）。要做增量：
1. 先缓存历史条目的 (hash, blurVar)（需要 fork 暴露或在外部再计算）
2. 新增文件只与新增 + 历史做 pairwise（你可自行替换为更高效结构）
3. 之后再把完整列表重新跑一次或只跑新增集合并合并结果（此库暂不直接支持增量 API）。

### 最小 vs. 完整字节
建议直接存放压缩格式原始 bytes（JPEG/PNG）即可；库内部会自行 decode & resize (32x32) 做哈希，不需要你先行缩放。

---

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
- duplicate/similar/blur 是“标签”概念，可重叠；`other` = 未命中这些标签与显式媒体类型的剩余条目。
- screenshot / video：由调用方在 `InMemoryImageEntry` 中的 `type` 显式标记得到。
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
