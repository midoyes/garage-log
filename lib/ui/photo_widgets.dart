import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// 方形縮圖。圖檔不在這台裝置上（例如從備份還原、只有記錄沒有圖檔）時顯示提示圖示。
class PhotoThumb extends ConsumerWidget {
  const PhotoThumb({super.key, required this.fileName, this.size = 72, this.onTap});

  final String fileName;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(photoStoreProvider).valueOrNull;
    final theme = Theme.of(context);
    Widget child;
    if (store == null) {
      child = const SizedBox.shrink();
    } else {
      final file = store.fileOf(fileName);
      child = Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: (size * 3).round(), // 縮圖只解碼小尺寸，列表很多張也不吃記憶體
        errorBuilder: (_, __, ___) => Center(
          child: Icon(Icons.image_not_supported_outlined,
              color: theme.colorScheme.outline),
        ),
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: size,
          height: size,
          color: theme.colorScheme.surfaceContainerHighest,
          child: child,
        ),
      ),
    );
  }
}

/// 全螢幕看照片：左右滑動切換、雙指縮放。
class PhotoViewerPage extends ConsumerStatefulWidget {
  const PhotoViewerPage({super.key, required this.fileNames, this.initial = 0});

  final List<String> fileNames;
  final int initial;

  @override
  ConsumerState<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends ConsumerState<PhotoViewerPage> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initial.clamp(0, widget.fileNames.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(photoStoreProvider).valueOrNull;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.fileNames.length}'),
      ),
      body: store == null
          ? const Center(child: CircularProgressIndicator())
          : PageView.builder(
              controller: _controller,
              itemCount: widget.fileNames.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: Image.file(
                    File(store.fileOf(widget.fileNames[i]).path),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '這張照片的圖檔不在這台裝置上',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

void openPhotoViewer(BuildContext context, List<String> fileNames, int initial) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PhotoViewerPage(fileNames: fileNames, initial: initial),
  ));
}
